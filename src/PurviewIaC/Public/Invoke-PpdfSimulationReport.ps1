function Invoke-PpdfSimulationReport {
    <#
    .SYNOPSIS
    Shows what policies deployed in simulation would have done, and whether each one is ready to enforce. Read-only.

    .DESCRIPTION
    For each selected artifact, finds the object carrying its simulation (the simulate-stage policy, or the
    "<name>-ppdfsim" shadow copy when the live policy is already enforced) and collects metrics by kind:
      DlpPolicy (mode)        totalMatches, matchesPerDay (peak day), distinctUsers, matchesPerRule (busiest
                              rule), distributionSuccess, plus per-rule and per-workload breakdowns, from
                              Activity Explorer DLPRuleMatch events since the simulation was deployed
      RetentionPolicy (mode)  distributionSuccess
      SensitiveInfoType-      precision, recall, falsePositives from running spec.testCorpusFile through
      RulePackage (corpus)    Test-DataClassification
      soakHours               hours since the simulation was deployed (all 'mode' kinds)
    Kinds with no simulation equivalent (role groups, Entra role assignments, retention label policies) are
    reported as 'deferred': they are reviewed as a what-if plan and gated by approval instead.

    Metrics are checked against thresholds (later wins):
      1. kind defaults        (see Get-PpdfKind; e.g. DlpPolicy requireDistributionSuccess: true)
      2. environment          spec.simulation.thresholds.<Kind> and spec.simulation.minSoakHours
      3. artifact             simulation.thresholds in the artifact file
    Naming convention: maxX means metric x <= value, minX means x >= value, requireX means x must be true.

    Status per artifact:
      pass              all thresholds met; Invoke-PpdfPromote allows enforcement
      soaking           only minSoakHours is unmet; wait and re-run
      fail              a threshold is not met; tune the policy (or threshold) and re-apply the simulate stage
      missing           nothing deployed in simulation yet; plan and apply with -Stage simulate first
      stale             what is deployed differs from the current config; re-apply the simulate stage
      already-enforced, deferred, not-applicable, skipped
                        no evidence needed or possible; these do not fail the report

    Writes simulation-report.json (+ .sha256 sidecar) and simulation-report.md. Keep the JSON: pass it to
    Invoke-PpdfPromote so approvers see the same evidence the gate evaluated.

    .PARAMETER Environment
    Environment name (environments/<name>.yml).

    .PARAMETER ConfigRoot
    Folder containing environments/ and artifacts/. Defaults to $env:PPDF_CONFIG_ROOT, then ./config.

    .PARAMETER OutputPath
    Folder for the report files and the run log. Defaults to ./out.

    .PARAMETER Artifact
    Limit the report to these artifacts (name or Kind/name).

    .PARAMETER Workload
    Limit the report to these workloads: dlp, retention, classifier, rbac.

    .PARAMETER UseExistingConnection
    Do not sign in; use the session already open in this PowerShell session (see Invoke-PpdfPlan).

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command, ReportPath, ReportHash, Pass (true when every artifact passed) and
    Report (the full report document).

    .NOTES
    Identity: spec.identities.reader. Activity Explorer data needs a role that can read it (see docs/identities.md).
    Exit codes: 0 report passes; 3 at least one artifact is fail, soaking, missing or stale; 1 error.
    Orchestrator outputs: sim_report_path, sim_report_hash, sim_pass.
    Activity Explorer can lag by up to 24-48 hours; a short soak period may show too few matches to judge.
    CLI: pwsh ./cli/ppdf.ps1 simulation-report -Environment prod -OutputPath ./out/sim

    .EXAMPLE
    Invoke-PpdfSimulationReport -Environment prod -ConfigRoot ./config -OutputPath ./out/sim

    Builds the report for all simulated artifacts in prod. Open ./out/sim/simulation-report.md to read it.

    .EXAMPLE
    $r = Invoke-PpdfSimulationReport -Environment prod -Artifact Finance-PCI
    $r.Report.artifacts | Format-Table id, status, soakHours, notes
    $r.Report.artifacts[0].checks | Format-Table name, actual, threshold, pass

    Checks a single DLP policy and lists why it is (or is not) ready.

    .EXAMPLE
    pwsh ./cli/ppdf.ps1 simulation-report -Environment prod -OutputPath ./out/sim
    pwsh ./cli/ppdf.ps1 promote -Environment prod -SimulationReportPath ./out/sim/simulation-report.json

    Produces the evidence, then plans promotion to enforcement based on exactly that evidence.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfPromote
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [string]$ConfigRoot,
        [string]$OutputPath,
        [string[]]$Artifact,
        [string[]]$Workload,
        [switch]$UseExistingConnection
    )
    Initialize-PpdfRun -Command 'simulation-report' -OutputPath $OutputPath | Out-Null
    $script:SkipConnect = [bool]$UseExistingConnection
    try {
        $ctx = Get-PpdfContext -ConfigRoot $ConfigRoot -Environment $Environment -Artifact $Artifact -Workload $Workload
        Write-PpdfContextIssue -Context $ctx
        if ($ctx.Errors.Count) { return New-PpdfResult -ExitCode 1 -Command 'simulation-report' -Data @{ Errors = @($ctx.Errors) } }
        $r = Invoke-PpdfSimulationReportCore -Context $ctx -OutputPath $script:Run.outputPath
        return New-PpdfResult -ExitCode $r.ExitCode -Command 'simulation-report' -Data @{ ReportPath = $r.Path; ReportHash = $r.Hash; Pass = $r.Report.pass; Report = $r.Report }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'simulation-report' -Data @{ Error = $_.Exception.Message }
    }
    finally { $script:SkipConnect = $false }
}

function Invoke-PpdfPromote {
    <#
    .SYNOPSIS
    Plans the move from simulation to enforcement ("go live"), allowed only for artifacts whose simulation passed.

    .DESCRIPTION
    Same as Invoke-PpdfPlan -Stage enforce, with the simulation report attached as evidence. For every artifact
    whose kind requires simulation evidence (DlpPolicy, RetentionPolicy, SensitiveInfoTypeRulePackage), the
    switch to enforcement is allowed only when the report says 'pass' (or 'already-enforced') for exactly the
    configuration being promoted (the artifact hash must match). Otherwise the action is blocked with the reason.
    A DLP shadow simulation copy ("<name>-ppdfsim") that is no longer needed is planned for removal.

    If -SimulationReportPath is omitted, a fresh report is generated first and saved next to the plan as
    simulation-report.json.

    Promote only plans. The result must still go through approval and Invoke-PpdfApply, exactly like any other
    plan. Going to enforcement usually needs a higher approval tier than simulation.

    .PARAMETER Environment
    Environment name (environments/<name>.yml).

    .PARAMETER SimulationReportPath
    simulation-report.json produced by Invoke-PpdfSimulationReport. Use this so the approver reviews the same
    evidence the gate used. Its .sha256 sidecar must be present and match.

    .PARAMETER ConfigRoot
    Folder containing environments/ and artifacts/. Defaults to $env:PPDF_CONFIG_ROOT, then ./config.

    .PARAMETER OutputPath
    Folder for the plan, the generated report (if any) and the run log. Defaults to ./out.

    .PARAMETER Artifact
    Promote only these artifacts (name or Kind/name). Recommended: promote one policy at a time in production.

    .PARAMETER Workload
    Limit to these workloads: dlp, retention, classifier, rbac.

    .PARAMETER UseExistingConnection
    Do not sign in; use the session already open in this PowerShell session (see Invoke-PpdfPlan).

    .INPUTS
    None.

    .OUTPUTS
    The same object as Invoke-PpdfPlan: ExitCode, Command, PlanPath, PlanHash, Summary, ApprovalTier,
    ApprovalEnvironment and Plan.

    .NOTES
    Identity: spec.identities.reader.
    Exit codes: 0 nothing to promote; 2 promotion planned, awaiting approval; 3 blocked (evidence missing, failing,
    soaking or stale); 1 error.
    CLI: pwsh ./cli/ppdf.ps1 promote -Environment prod [-Artifact Finance-PCI] [-SimulationReportPath ...]

    .EXAMPLE
    Invoke-PpdfPromote -Environment prod -SimulationReportPath ./out/sim/simulation-report.json -OutputPath ./out/promote

    Plans enforcement for every simulated artifact whose evidence passed. Read ./out/promote/plan.md for blocked
    items and their reasons.

    .EXAMPLE
    Invoke-PpdfPromote -Environment prod -Artifact Finance-PCI -OutputPath ./out/promote

    Generates fresh evidence and plans enforcement of one DLP policy.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfSimulationReport

    .LINK
    Invoke-PpdfApply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [string]$SimulationReportPath,
        [string]$ConfigRoot,
        [string]$OutputPath,
        [string[]]$Artifact,
        [string[]]$Workload,
        [switch]$UseExistingConnection
    )
    Initialize-PpdfRun -Command 'promote' -OutputPath $OutputPath | Out-Null
    $script:SkipConnect = [bool]$UseExistingConnection
    try {
        $ctx = Get-PpdfContext -ConfigRoot $ConfigRoot -Environment $Environment -Artifact $Artifact -Workload $Workload
        Write-PpdfContextIssue -Context $ctx
        if ($ctx.Errors.Count) { return New-PpdfResult -ExitCode 1 -Command 'promote' -Data @{ Errors = @($ctx.Errors) } }
        if (-not $SimulationReportPath) {
            Write-PpdfLog -Message 'No simulation report supplied; generating one now.'
            $SimulationReportPath = (Invoke-PpdfSimulationReportCore -Context $ctx -OutputPath $script:Run.outputPath).Path
        }
        $r = Invoke-PpdfPlanCore -Context $ctx -Stage 'enforce' -SimulationReportPath (Resolve-Path -LiteralPath $SimulationReportPath -ErrorAction SilentlyContinue).Path -OutputPath $script:Run.outputPath
        return New-PpdfResult -ExitCode $r.ExitCode -Command 'promote' -Data @{ PlanPath = $r.Path; PlanHash = $r.Hash; Summary = $r.Plan.summary; ApprovalTier = $r.Plan.requiredApprovalTier; ApprovalEnvironment = $r.Plan.approvalEnvironment; Plan = $r.Plan }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'promote' -Data @{ Error = $_.Exception.Message }
    }
    finally { $script:SkipConnect = $false }
}

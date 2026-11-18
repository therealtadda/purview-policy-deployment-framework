function Invoke-PpdfApply {
    <#
    .SYNOPSIS
    Makes the changes in an approved plan, exactly as planned, using the least-privilege identity for each workload.

    .DESCRIPTION
    Apply never re-plans: it executes the actions recorded in plan.json, so what was approved is what is
    deployed. Before changing anything it refuses (exit 3, nothing changed) when:
      * plan.json does not match its .sha256 sidecar, or does not match -ExpectedPlanHash (the hash the
        approver saw);
      * the plan contains blocked actions;
      * -ApprovedTier is lower than the plan's requiredApprovalTier (low < standard < elevated < critical);
      * the plan is older than approvals.maxPlanAgeHours in the environment (default 24 hours).

    Actions are then grouped by identity role (dlp, retention, classifier, rbac). For each group PPDF signs in as
    that role's identity only, and first re-reads every object the group will touch. If anything changed since
    the plan was made (someone edited it in the portal, or another run got there first), the whole group is
    skipped as 'skipped-stale' and nothing in it is changed. Otherwise actions run in dependency order. On the
    first failure the remaining actions are marked 'not-run' and apply stops; re-plan to continue.

    Writes to the output path:
      apply-result.json (+ .sha256) and apply-result.md   per-action status
      evidence/                                            plan, plan hash, plan.md, simulation report,
                                                           apply result and run log, with manifest.json hashes
    Keep the evidence folder (pipeline artifact) for audit and for Invoke-PpdfRollback.

    .PARAMETER PlanPath
    plan.json (or rollback-plan.json) produced by plan, promote, drift or rollback. Keep the .sha256 sidecar next
    to it.

    .PARAMETER ExpectedPlanHash
    The plan hash the approver reviewed (plan_hash output of the plan job). Always pass this in pipelines; it
    makes sure the file was not swapped between approval and apply. If omitted, only the sidecar is checked and a
    warning is logged.

    .PARAMETER ApprovedTier
    The approval tier this run was approved for: low, standard, elevated or critical. In pipelines, this is the
    tier of the approval gate (GitHub environment / Azure DevOps environment / Terraform approved_tier) that
    guarded the job. If omitted, the tier check is skipped; only do that for local, non-production use.

    .PARAMETER Workload
    Apply only the actions of these workloads (dlp, retention, classifier, rbac). Pipelines run one apply job per
    workload so each job only has the credentials of one deployer identity.

    .PARAMETER OutputPath
    Folder for apply-result files, the evidence bundle and the run log. Defaults to ./out.

    .PARAMETER UseExistingConnection
    Do not sign in as the deployer identities; use the session already open in this PowerShell session. For
    local testing against a lab tenant only.

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command, ResultPath, ResultHash, EvidencePath and Results (id, op, type, name,
    workload and status: succeeded, failed, not-run or skipped-stale). When refused: Refused = $true and Errors.

    .NOTES
    Identity: spec.identities.<role> for each workload in the plan (dlp, retention, classifier, rbac).
    Exit codes: 0 applied (or nothing to do); 3 refused or stale (nothing changed in the affected group);
    1 an action failed or an unexpected error occurred (partial apply possible; see apply-result.md).
    Orchestrator outputs: apply_result_path, evidence_path, ppdf_exit_code.
    CLI: pwsh ./cli/ppdf.ps1 apply -PlanPath ./out/plan.json -ExpectedPlanHash <hash> -ApprovedTier elevated

    .EXAMPLE
    $p = Invoke-PpdfPlan -Environment dev -OutputPath ./out/dev
    Get-Content ./out/dev/plan.md
    Invoke-PpdfApply -PlanPath $p.PlanPath -ExpectedPlanHash $p.PlanHash -ApprovedTier $p.ApprovalTier -OutputPath ./out/dev

    Local plan-review-apply loop for a dev tenant.

    .EXAMPLE
    pwsh ./cli/ppdf.ps1 apply -PlanPath ./plan/plan.json -ExpectedPlanHash $env:PLAN_HASH -ApprovedTier elevated -Workload dlp -OutputPath ./apply

    What the pipeline apply job runs after the 'elevated' approval gate: only DLP actions, with the DLP deployer
    identity.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfPlan

    .LINK
    Invoke-PpdfRollback
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [string]$ExpectedPlanHash,
        [ValidateSet('low', 'standard', 'elevated', 'critical')][string]$ApprovedTier,
        [string[]]$Workload,
        [string]$OutputPath,
        [switch]$UseExistingConnection
    )
    Initialize-PpdfRun -Command 'apply' -OutputPath $OutputPath | Out-Null
    $script:SkipConnect = [bool]$UseExistingConnection
    try {
        $integrity = Test-PpdfDocumentIntegrity -Path $PlanPath -ExpectedHash $ExpectedPlanHash
        if (-not $integrity.Valid) {
            foreach ($e in $integrity.Errors) { Write-PpdfLog -Level error -Message $e }
            return New-PpdfResult -ExitCode 3 -Command 'apply' -Data @{ Refused = $true; Errors = $integrity.Errors }
        }
        if (-not $ExpectedPlanHash) { Write-PpdfLog -Level warn -Message 'No -ExpectedPlanHash supplied; relying on the .sha256 sidecar only. Pipelines should pass the approved plan hash.' }
        $plan = Read-PpdfJson -Path $PlanPath
        if ($plan.type -ne 'ppdf-plan') { throw 'File is not a ppdf plan.' }
        $refuse = [System.Collections.Generic.List[string]]::new()
        if ([int]$plan.summary.blocked -gt 0) { $refuse.Add("Plan contains $($plan.summary.blocked) blocked action(s).") }
        if ($ApprovedTier -and (Get-PpdfTierRank $plan.requiredApprovalTier) -gt (Get-PpdfTierRank $ApprovedTier)) {
            $refuse.Add("Plan requires '$($plan.requiredApprovalTier)' approval but this job was approved at '$ApprovedTier'.")
        }
        $maxAge = [double](Get-PpdfValue (Get-PpdfValue $plan.environmentSpec 'approvals' @{}) 'maxPlanAgeHours' 24)
        $created = [datetime]::Parse([string]$plan.createdUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        if (((Get-Date).ToUniversalTime() - $created).TotalHours -gt $maxAge) { $refuse.Add("Plan is older than $maxAge hours; re-plan and re-approve.") }
        if ($refuse.Count) {
            foreach ($e in $refuse) { Write-PpdfLog -Level error -Message $e }
            return New-PpdfResult -ExitCode 3 -Command 'apply' -Data @{ Refused = $true; Errors = $refuse.ToArray() }
        }
        Write-PpdfLog -Message "Applying plan $($integrity.Hash) to '$($plan.environment)' ($($plan.stage)); $(@($plan.actions).Count) action(s)."
        $exec = if (@($plan.actions).Count) { Invoke-PpdfPlanApply -Plan $plan -Workload $Workload } else { @{ ExitCode = 0; Results = @() } }
        $result = [ordered]@{
            type         = 'ppdf-apply-result'
            environment  = $plan.environment
            stage        = $plan.stage
            planHash     = $integrity.Hash
            approvedTier = $ApprovedTier
            startedUtc   = $script:Run.startedUtc
            finishedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            orchestrator = $script:Run.orchestrator
            exitCode     = $exec.ExitCode
            results      = @($exec.Results)
        }
        $resultPath = Join-Path $script:Run.outputPath 'apply-result.json'
        $resultHash = Save-PpdfDocument -Document $result -Path $resultPath
        $md = Join-Path $script:Run.outputPath 'apply-result.md'
        $lines = @("## Purview apply - ``$($plan.environment)`` ($($plan.stage))", '', "Plan hash: ``$($integrity.Hash)``  ", "Result: exit $($exec.ExitCode)", '', '| # | op | type | name | status |', '|---|---|---|---|---|')
        $lines += @($exec.Results | ForEach-Object { "| $($_.id) | $($_.op) | $($_.type) | $($_.name) | $($_.status) |" })
        Set-Content -LiteralPath $md -Value ($lines -join [Environment]::NewLine) -Encoding utf8NoBOM
        Add-PpdfSummary -Path $md
        $simPath = if ($plan.simulationReport) { [string]$plan.simulationReport.path } else { $null }
        $evidence = New-PpdfEvidenceBundle -OutputPath $script:Run.outputPath -Files @($PlanPath, "$PlanPath.sha256", ([System.IO.Path]::ChangeExtension($PlanPath, '.md')), $simPath, $resultPath, "$resultPath.sha256", $md, $script:Run.logPath)
        Set-PpdfOutput -Name 'apply_result_path' -Value $resultPath
        Set-PpdfOutput -Name 'evidence_path' -Value $evidence
        return New-PpdfResult -ExitCode $exec.ExitCode -Command 'apply' -Data @{ ResultPath = $resultPath; ResultHash = $resultHash; EvidencePath = $evidence; Results = @($exec.Results) }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'apply' -Data @{ Error = $_.Exception.Message }
    }
    finally { $script:SkipConnect = $false }
}

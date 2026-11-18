function Invoke-PpdfRollback {
    <#
    .SYNOPSIS
    Creates a plan that undoes a previous apply. Offline: builds the plan only, does not change the tenant.

    .DESCRIPTION
    Reads the original plan and its apply result, and for every action that succeeded builds the inverse action
    (create -> delete, update -> restore the previous values recorded in the plan, delete -> recreate), in reverse
    order. The output, rollback-plan.json (+ .sha256) and rollback-plan.md, is an ordinary plan: it is reviewed,
    approved (at least the 'elevated' tier) and applied with Invoke-PpdfApply like any other.

    At apply time the usual freshness checks run, so if the tenant has changed since the original apply the
    affected group is skipped rather than overwritten.

    Limitations: recreating a deleted object restores only the properties PPDF manages; data-plane effects (for
    example items already labelled or retained) are not reversed. For config mistakes, reverting the commit and
    deploying normally is usually better; rollback is for fast recovery from a bad apply.

    .PARAMETER PlanPath
    The plan.json that was applied. Usually from the evidence/ folder of the apply run (pipeline artifact). The
    plan.json.sha256 sidecar must be next to it.

    .PARAMETER ApplyResultPath
    The apply-result.json from that apply (same evidence/ folder), with its .sha256 sidecar. It must belong to
    the plan above (its planHash must match). Azure DevOps applies each workload in its own step, producing one
    apply-result.json per workload (out/apply-<workload>/evidence/); pass all of them, comma-separated on the CLI.

    .PARAMETER OutputPath
    Folder for rollback-plan files and the run log. Defaults to ./out.

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command, PlanPath, PlanHash and Plan (the rollback plan).

    .NOTES
    Identity: none to build the plan; the apply uses the normal deployer identities.
    Exit codes: 2 rollback plan produced (needs approval and apply); 0 nothing to roll back; 1 error (for example
    a hash mismatch).
    CLI: pwsh ./cli/ppdf.ps1 rollback -PlanPath ./evidence/plan.json -ApplyResultPath ./evidence/apply-result.json

    .EXAMPLE
    $rb = Invoke-PpdfRollback -PlanPath ./evidence/plan.json -ApplyResultPath ./evidence/apply-result.json -OutputPath ./out/rollback
    Get-Content ./out/rollback/rollback-plan.md
    Invoke-PpdfApply -PlanPath $rb.PlanPath -ExpectedPlanHash $rb.PlanHash -ApprovedTier elevated -OutputPath ./out/rollback

    Builds, reviews and applies a rollback locally (lab tenant). In production use the pipeline's rollback
    command (GitHub: ppdf-plan.yml command 'rollback' with rollback-run-id; Azure DevOps: stage-plan.yml command
    'rollback' with rollbackRunId), so the rollback plan goes through the approval gate like any other plan.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfApply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string[]]$ApplyResultPath,
        [string]$OutputPath
    )
    Initialize-PpdfRun -Command 'rollback' -OutputPath $OutputPath | Out-Null
    try {
        foreach ($p in @($PlanPath) + @($ApplyResultPath)) {
            $i = Test-PpdfDocumentIntegrity -Path $p
            if (-not $i.Valid) { throw ($i.Errors -join ' ') }
        }
        $plan = Read-PpdfJson -Path $PlanPath
        $planHash = (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $applied = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $ApplyResultPath) {
            $one = Read-PpdfJson -Path $p
            if ($one.type -ne 'ppdf-apply-result') { throw "$(Split-Path -Leaf $p) is not a ppdf apply result." }
            if ($one.planHash -ne $planHash) { throw "$p does not belong to this plan (plan hash mismatch)." }
            foreach ($r in @($one.results)) { $applied.Add($r) }
        }
        $inverse = @(New-PpdfRollbackAction -Plan $plan -ApplyResult @{ results = $applied.ToArray() })
        # Reverse chronological order: undo the last change first.
        [array]::Reverse($inverse)
        $n = 0
        foreach ($a in $inverse) { $n++; $a.id = '{0:d3}' -f $n }
        $ctx = @{ Env = $plan.environmentSpec; EnvName = $plan.environment; ConfigHash = $plan.configHash }
        $doc = New-PpdfPlanDocument -Context $ctx -Result @{ Actions = $inverse; Artifacts = @(); Noop = 0; Evidence = $null } -Stage ([string]$plan.stage) -RollbackOf $planHash
        $path = Join-Path $script:Run.outputPath 'rollback-plan.json'
        $hash = Save-PpdfDocument -Document $doc -Path $path
        $md = Join-Path $script:Run.outputPath 'rollback-plan.md'
        Set-Content -LiteralPath $md -Value (ConvertTo-PpdfPlanMarkdown -Plan $doc -Hash $hash) -Encoding utf8NoBOM
        Add-PpdfSummary -Path $md
        Set-PpdfOutput -Name 'plan_path' -Value $path
        Set-PpdfOutput -Name 'plan_hash' -Value $hash
        Set-PpdfOutput -Name 'approval_tier' -Value $doc.requiredApprovalTier
        Set-PpdfOutput -Name 'approval_environment' -Value $doc.approvalEnvironment
        Set-PpdfOutput -Name 'has_changes' -Value ([string]($inverse.Count -gt 0)).ToLowerInvariant()
        Set-PpdfOutput -Name 'blocked' -Value 'false'
        Set-PpdfOutput -Name 'workloads' -Value ((@($inverse | ForEach-Object { $_.workload }) | Sort-Object -Unique) -join ',')
        Write-PpdfLog -Message "Rollback plan with $($inverse.Count) action(s) written to $path (hash $hash)."
        $exit = if ($inverse.Count) { 2 } else { 0 }
        return New-PpdfResult -ExitCode $exit -Command 'rollback' -Data @{ PlanPath = $path; PlanHash = $hash; Plan = $doc }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'rollback' -Data @{ Error = $_.Exception.Message }
    }
}

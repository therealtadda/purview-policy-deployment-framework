function Invoke-PpdfPlan {
    <#
    .SYNOPSIS
    Works out what would change in the tenant to match the configuration. Read-only: nothing is changed.

    .DESCRIPTION
    Signs in as the environment's reader identity, reads the current state of every selected artifact, and compares
    it with the configuration for the requested stage. Each difference becomes an action (create, update, adopt or
    delete) with a risk tier. The highest tier decides which approval gate the plan needs.

    Writes to the output path:
      plan.json         the machine-readable plan that apply will execute
      plan.json.sha256  its SHA-256 hash; the hash is what approvers sign off on and what apply verifies
      plan.md           a human-readable summary for reviewers (also added to the job summary)
    In GitHub Actions and Azure DevOps it also publishes plan_path, plan_hash, has_changes, blocked,
    approval_tier, approval_environment and workloads as step outputs.

    An action is "blocked" when PPDF refuses to apply it whatever the approval, for example:
      * the object exists but is not managed by PPDF (set metadata.adopt: true to take it over);
      * the object is owned by a different artifact;
      * enforcing a kind that needs simulation evidence without a passing simulation report for this exact
        config (use Invoke-PpdfPromote);
      * deleting an orphaned object without spec.allowDestructive: true or a metadata.ensure: absent artifact.
    Fix blocked actions in config or in the tenant and plan again. The reasons are listed in plan.md.

    .PARAMETER Environment
    Environment name (environments/<name>.yml). Selects the tenant, the identities, the approval settings and the
    artifacts that apply to that environment.

    .PARAMETER Stage
    simulate  - deploy policies in their simulation/test mode (DLP TestWithoutNotifications unless the artifact's
                simulation.mode says otherwise). Default. Kinds with no simulation equivalent (role groups, Entra
                role assignments, retention label policies) and artifacts with simulation.skip are 'deferred': the
                plan shows their what-if but they are only applied at the enforce stage. A policy that is already
                enforced is never switched back to test mode; DLP changes are simulated in a '-ppdfsim' shadow copy.
    enforce   - deploy in enforcement mode. Kinds that need simulation evidence are blocked unless
                -SimulationReportPath has a passing report for the same config; Invoke-PpdfPromote does this for you.
    auto      - keep each object at the stage it is currently deployed in (recorded in its PPDF ownership tag);
                existing objects without a tag (being adopted) are compared as enforced, so adoption never
                switches a live policy to test mode; objects not yet deployed are planned at simulate. No
                simulation evidence is checked. Used by Invoke-PpdfDrift, brownfield adoption and by pipelines that
                roll out config changes without changing stage.

    .PARAMETER ConfigRoot
    Folder containing environments/ and artifacts/. Defaults to $env:PPDF_CONFIG_ROOT, then ./config.

    .PARAMETER OutputPath
    Folder for the plan files and the run log. Defaults to ./out. Use a separate folder per environment.

    .PARAMETER Artifact
    Limit the plan to these artifacts. Use the artifact name or the Kind/name id (for example
    DlpPolicy/Finance-PCI). Dependencies are not added automatically.

    .PARAMETER Workload
    Limit the plan to these workloads: dlp, retention, classifier, rbac. Pipelines use this to split one plan into
    workload-specific apply jobs, each with its own identity.

    .PARAMETER SimulationReportPath
    Simulation report (from Invoke-PpdfSimulationReport) to attach as evidence. Needed only when -Stage enforce
    or auto includes kinds that require evidence; Invoke-PpdfPromote handles this for you.

    .PARAMETER UseExistingConnection
    Do not sign in; use the Security & Compliance / Graph session already open in this PowerShell session.
    Useful for local exploration after Connect-IPPSSession. Same as setting $env:PPDF_SKIP_CONNECT = '1'.

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command, PlanPath, PlanHash, Summary (create/update/adopt/delete/noop/blocked/
    deferred counts), ApprovalTier, ApprovalEnvironment and Plan (the full plan document).

    .NOTES
    Identity: spec.identities.reader of the environment (read-only roles only).
    Exit codes: 0 no changes; 2 changes pending approval; 3 plan contains blocked actions; 1 error.
    Plans expire: apply refuses plans older than approvals.maxPlanAgeHours (default 24).
    CLI: pwsh ./cli/ppdf.ps1 plan -Environment dev -Stage simulate [-Workload dlp] [-OutputPath ./out/dev]

    .EXAMPLE
    Invoke-PpdfPlan -Environment dev -Stage simulate -ConfigRoot ./config -OutputPath ./out/dev

    Plans a simulation-mode deployment to dev. Review ./out/dev/plan.md, then apply with the hash it prints.

    .EXAMPLE
    pwsh ./cli/ppdf.ps1 plan -Environment prod -Stage auto -Workload dlp,retention -OutputPath ./out/prod

    Plans only DLP and retention changes for prod from the command line. Exit code 2 means changes are waiting.

    .EXAMPLE
    Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
    Invoke-PpdfPlan -Environment dev -UseExistingConnection

    Plans using your own interactive session instead of the reader identity, for local troubleshooting only. Your
    account needs at least the same read permissions as the reader identity.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfApply

    .LINK
    Invoke-PpdfPromote
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [ValidateSet('simulate', 'enforce', 'auto')][string]$Stage = 'simulate',
        [string]$ConfigRoot,
        [string]$OutputPath,
        [string[]]$Artifact,
        [string[]]$Workload,
        [string]$SimulationReportPath,
        [switch]$UseExistingConnection
    )
    Initialize-PpdfRun -Command 'plan' -OutputPath $OutputPath | Out-Null
    $script:SkipConnect = [bool]$UseExistingConnection
    try {
        $ctx = Get-PpdfContext -ConfigRoot $ConfigRoot -Environment $Environment -Artifact $Artifact -Workload $Workload
        Write-PpdfContextIssue -Context $ctx
        if ($ctx.Errors.Count) { return New-PpdfResult -ExitCode 1 -Command 'plan' -Data @{ Errors = @($ctx.Errors) } }
        $r = Invoke-PpdfPlanCore -Context $ctx -Stage $Stage -SimulationReportPath $SimulationReportPath -OutputPath $script:Run.outputPath
        return New-PpdfResult -ExitCode $r.ExitCode -Command 'plan' -Data @{ PlanPath = $r.Path; PlanHash = $r.Hash; Summary = $r.Plan.summary; ApprovalTier = $r.Plan.requiredApprovalTier; ApprovalEnvironment = $r.Plan.approvalEnvironment; Plan = $r.Plan }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'plan' -Data @{ Error = $_.Exception.Message }
    }
    finally { $script:SkipConnect = $false }
}

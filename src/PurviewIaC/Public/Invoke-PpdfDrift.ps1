function Invoke-PpdfDrift {
    <#
    .SYNOPSIS
    Finds differences between the tenant and the configuration (portal edits, deleted objects). Read-only.

    .DESCRIPTION
    Runs a plan with -Stage auto (each object compared at the stage it is currently deployed in) and reports every
    difference as drift. Typical causes: someone changed a managed policy in the portal, deleted it, or created
    an object with the same name outside PPDF. Run it on a schedule (the example pipelines run it nightly).

    drift.json is a normal plan document, so it can be reviewed and applied with Invoke-PpdfApply to put the tenant
    back to the configuration. Alternatively, accept the change by updating the configuration (Invoke-PpdfExport
    helps capture the current values).

    Writes drift.json (+ .sha256) and drift.md; publishes drift_detected plus the same outputs as plan.

    .PARAMETER Environment
    Environment name (environments/<name>.yml).

    .PARAMETER ConfigRoot
    Folder containing environments/ and artifacts/. Defaults to $env:PPDF_CONFIG_ROOT, then ./config.

    .PARAMETER OutputPath
    Folder for drift files and the run log. Defaults to ./out.

    .PARAMETER Artifact
    Check only these artifacts (name or Kind/name).

    .PARAMETER Workload
    Check only these workloads: dlp, retention, classifier, rbac.

    .PARAMETER UseExistingConnection
    Do not sign in; use the session already open in this PowerShell session (see Invoke-PpdfPlan).

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command, DriftDetected, PlanPath, PlanHash, Summary and Plan.

    .NOTES
    Identity: spec.identities.reader.
    Exit codes: 0 no drift; 2 drift found; 3 drift found that cannot be auto-corrected (blocked, e.g. an
    unmanaged object with a managed name); 1 error. Schedulers should alert on 2 and 3.
    CLI: pwsh ./cli/ppdf.ps1 drift -Environment prod -OutputPath ./out/drift

    .EXAMPLE
    Invoke-PpdfDrift -Environment prod -ConfigRoot ./config -OutputPath ./out/drift

    Checks prod and writes ./out/drift/drift.md.

    .EXAMPLE
    $d = Invoke-PpdfDrift -Environment prod -Workload rbac
    if ($d.DriftDetected) { $d.Plan.actions | Format-Table op, type, name, diffKeys }

    Checks only role groups and Entra role assignments, and lists what differs.

    .EXAMPLE
    $d = Invoke-PpdfDrift -Environment prod -OutputPath ./out/drift
    Invoke-PpdfApply -PlanPath $d.PlanPath -ExpectedPlanHash $d.PlanHash -ApprovedTier elevated -OutputPath ./out/drift

    Reverts the drift. In production do this through the pipeline so the approval gate applies.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfExport
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
    Initialize-PpdfRun -Command 'drift' -OutputPath $OutputPath | Out-Null
    $script:SkipConnect = [bool]$UseExistingConnection
    try {
        $ctx = Get-PpdfContext -ConfigRoot $ConfigRoot -Environment $Environment -Artifact $Artifact -Workload $Workload
        Write-PpdfContextIssue -Context $ctx
        if ($ctx.Errors.Count) { return New-PpdfResult -ExitCode 1 -Command 'drift' -Data @{ Errors = @($ctx.Errors) } }
        $r = Invoke-PpdfPlanCore -Context $ctx -Stage 'auto' -OutputPath $script:Run.outputPath -FileBase 'drift'
        $drift = @($r.Plan.actions).Count -gt 0
        Set-PpdfOutput -Name 'drift_detected' -Value ([string]$drift).ToLowerInvariant()
        if ($drift) { Write-PpdfLog -Level warn -Message "Drift detected in '$Environment': $(@($r.Plan.actions).Count) difference(s). See drift.md." }
        return New-PpdfResult -ExitCode $r.ExitCode -Command 'drift' -Data @{ DriftDetected = $drift; PlanPath = $r.Path; PlanHash = $r.Hash; Summary = $r.Plan.summary; Plan = $r.Plan }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'drift' -Data @{ Error = $_.Exception.Message }
    }
    finally { $script:SkipConnect = $false }
}

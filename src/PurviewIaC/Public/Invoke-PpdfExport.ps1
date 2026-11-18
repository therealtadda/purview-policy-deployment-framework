function Invoke-PpdfExport {
    <#
    .SYNOPSIS
    Writes the tenant's existing Purview configuration out as PPDF artifact files, to start managing it as code. Read-only.

    .DESCRIPTION
    For brownfield tenants. Each exportable kind (see Get-PpdfKind | Where-Object Exportable) reads what exists
    and writes one artifact per object to <OutputPath>/<Kind>/<name>.yml, plus any companion files (for example
    a SIT rule package .xml and a starter .corpus.yml). If no YAML serializer is available, .json is written.

    Exported artifacts carry metadata.adopt: true. On the first plan PPDF then adopts (tags) the existing objects
    instead of blocking them as unmanaged. Remove adopt once the first apply has succeeded.

    Recommended onboarding:
      1. Export, then review and tidy the files (names, ${variables}, environments).
      2. Move them under config/artifacts and run Invoke-PpdfValidate.
      3. Run Invoke-PpdfPlan -Stage auto: existing objects are compared as they are deployed (not switched to
         test mode), so expect only 'adopt' actions. Any diffKeys besides the ownership tag mean the export and
         the config differ; fix the config, not the tenant.
      4. Apply through the pipeline, then remove metadata.adopt.
    Not exported: Microsoft-published SIT rule packages, PPDF '-ppdfsim' shadow DLP copies, retention policies
    that publish or auto-apply labels or have more than one rule, and Entra role assignments for roles outside the
    environment's guardrails.entraRoleAllowlist. Role groups not created by PPDF (including built-in groups) are
    exported as membershipOnly: true, so PPDF manages their members but never their roles. Exported Entra role
    assignments with an end date get duration P365D; review it before applying.

    .PARAMETER Environment
    Environment name whose tenant and reader identity are used.

    .PARAMETER Kind
    Export only these kinds (for example DlpPolicy, RetentionPolicy, SensitiveInfoTypeRulePackage, RoleGroup).
    Default: every exportable kind.

    .PARAMETER ConfigRoot
    Folder containing environments/. Defaults to $env:PPDF_CONFIG_ROOT, then ./config.

    .PARAMETER OutputPath
    Folder to write the files to. Defaults to ./out. Use a folder outside config/ so nothing is picked up by
    accident before review.

    .PARAMETER UseExistingConnection
    Do not sign in; use the session already open in this PowerShell session (see Invoke-PpdfPlan).

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command and Files (paths written).

    .NOTES
    Identity: spec.identities.reader. Nothing is changed in the tenant.
    Exit codes: 0 success; 1 error.
    CLI: pwsh ./cli/ppdf.ps1 export -Environment prod -Kind DlpPolicy -OutputPath ./export

    .EXAMPLE
    Invoke-PpdfExport -Environment prod -Kind DlpPolicy,RetentionPolicy -OutputPath ./export

    Exports DLP and retention policies from prod to ./export/DlpPolicy and ./export/RetentionPolicy.

    .EXAMPLE
    Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
    Invoke-PpdfExport -Environment prod -UseExistingConnection -OutputPath ./export

    Exports everything using your own interactive session, before the reader identity has been created.

    .LINK
    about_PurviewIaC

    .LINK
    Get-PpdfKind
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [string[]]$Kind,
        [string]$ConfigRoot,
        [string]$OutputPath,
        [switch]$UseExistingConnection
    )
    Initialize-PpdfRun -Command 'export' -OutputPath $OutputPath | Out-Null
    $script:SkipConnect = [bool]$UseExistingConnection
    try {
        $ctx = Get-PpdfContext -ConfigRoot $ConfigRoot -Environment $Environment -Artifact @('__ppdf_export_none__')
        if (-not $ctx.Env) { throw "Environment '$Environment' could not be loaded: $($ctx.Errors -join '; ')" }
        $kinds = @($script:Kinds.Values | Where-Object { $_.Export -and (-not $Kind -or $_.Name -in $Kind) })
        if (-not $kinds) { throw 'No exportable kinds selected.' }
        $services = @($kinds | ForEach-Object { $w = $_.Workload; $script:ObjectTypes.Values | Where-Object { $_.Workload -eq $w } | ForEach-Object { $_.Service } } | Select-Object -Unique)
        if (-not $services) { $services = @('scc') }
        $written = [System.Collections.Generic.List[string]]::new()
        Connect-PpdfIdentity -Role 'reader' -EnvSpec $ctx.Env -Services $services
        try {
            foreach ($k in $kinds) {
                $items = @(& $k.Export $ctx)
                $dir = Join-Path $script:Run.outputPath $k.Name
                if ($items.Count -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                foreach ($item in $items) {
                    $safe = ($item.Name -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
                    $yaml = ConvertTo-PpdfYaml -InputObject $item.Doc
                    $file = if ($yaml) { Join-Path $dir "$safe.yml" } else { Join-Path $dir "$safe.json" }
                    if ($yaml) { Set-Content -LiteralPath $file -Value $yaml -Encoding utf8NoBOM } else { Write-PpdfJson -InputObject $item.Doc -Path $file }
                    $written.Add($file)
                    foreach ($f in @(if ($item.Files) { $item.Files.Keys })) {
                        $target = Join-Path $dir $f
                        $content = $item.Files[$f]
                        if ($content -is [byte[]]) { [System.IO.File]::WriteAllBytes($target, $content) } else { Set-Content -LiteralPath $target -Value $content -Encoding utf8NoBOM }
                        $written.Add($target)
                    }
                }
                Write-PpdfLog -Message "Exported $($items.Count) $($k.Name) artifact(s)."
            }
        }
        finally { Disconnect-PpdfIdentity }
        return New-PpdfResult -ExitCode 0 -Command 'export' -Data @{ Files = $written.ToArray() }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'export' -Data @{ Error = $_.Exception.Message }
    }
    finally { $script:SkipConnect = $false }
}

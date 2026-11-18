function Invoke-PpdfValidate {
    <#
    .SYNOPSIS
    Checks configuration for mistakes before anything touches a tenant. Offline: no sign-in, no tenant access.

    .DESCRIPTION
    Loads each environment file and every artifact it selects, then checks:
      * JSON Schema conformance (schemas/environment.schema.json, artifact.schema.json and the per-kind schemas);
      * provider rules a schema cannot express (for example DLP rule conditions, retention durations, SIT patterns);
      * ${variable} references, duplicate artifact names, environment guardrails (for example the Entra role
        allowlist) and referenced files (SIT rule-package XML, test corpora).

    Run it on every pull request and before every plan; the pipelines do this for you. Errors and warnings are
    printed to the console (and annotated in GitHub/Azure DevOps). The full result is written to validation.json.

    .PARAMETER Environment
    One or more environment names (file names under <ConfigRoot>/environments without the extension).
    Omit to validate every environment.

    .PARAMETER ConfigRoot
    Folder containing environments/ and artifacts/. Defaults to $env:PPDF_CONFIG_ROOT, then ./config.

    .PARAMETER OutputPath
    Folder for validation.json and the run log (ppdf-validate.log.jsonl). Defaults to ./out. Created if missing.

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject with ExitCode, Command, Valid, ErrorCount, Path (validation.json) and Environments
    (per-environment artifacts, errors, warnings and configHash).

    .NOTES
    Identity: none (offline).
    Exit codes: 0 valid; 1 one or more errors (or the configuration could not be read).
    CLI: pwsh ./cli/ppdf.ps1 validate [-Environment dev,prod] [-ConfigRoot ./config]

    .EXAMPLE
    Invoke-PpdfValidate -ConfigRoot ./config

    Validates every environment. Check the returned object's Valid property, or read out/validation.json.

    .EXAMPLE
    pwsh ./cli/ppdf.ps1 validate -Environment prod -ConfigRoot ./config

    Validates only prod from the command line; the process exit code is 0 when valid.

    .EXAMPLE
    (Invoke-PpdfValidate -ConfigRoot ./config).Environments['dev'].errors

    Lists the error messages for the dev environment.

    .LINK
    about_PurviewIaC

    .LINK
    Invoke-PpdfPlan
    #>
    [CmdletBinding()]
    param(
        [string[]]$Environment,
        [string]$ConfigRoot,
        [string]$OutputPath
    )
    Initialize-PpdfRun -Command 'validate' -OutputPath $OutputPath | Out-Null
    try {
        $root = Get-PpdfConfigRoot -ConfigRoot $ConfigRoot
        if (-not $Environment) {
            $Environment = @(Get-ChildItem -Path (Join-Path $root 'environments') -File |
                    Where-Object { $_.Extension -in '.yml', '.yaml', '.json' } | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
        }
        if (-not $Environment) { throw "No environments found under $root/environments." }
        $results = [ordered]@{}
        $total = 0
        foreach ($e in $Environment) {
            $ctx = Get-PpdfContext -ConfigRoot $root -Environment $e
            Write-PpdfContextIssue -Context $ctx
            $results[$e] = [ordered]@{ artifacts = @($ctx.Artifacts | ForEach-Object { [ordered]@{ id = $_.Id; sha = $_.Sha; path = $_.RelativePath } }); errors = @($ctx.Errors); warnings = @($ctx.Warnings); configHash = $ctx.ConfigHash }
            $total += $ctx.Errors.Count
            Write-PpdfLog -Message "Environment '$e': $(@($ctx.Artifacts).Count) artifact(s), $($ctx.Errors.Count) error(s)."
        }
        $doc = [ordered]@{ type = 'ppdf-validation'; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); valid = ($total -eq 0); environments = $results }
        $path = Join-Path $script:Run.outputPath 'validation.json'
        Write-PpdfJson -InputObject $doc -Path $path
        $exit = if ($total -eq 0) { 0 } else { 1 }
        return New-PpdfResult -ExitCode $exit -Command 'validate' -Data @{ Valid = ($total -eq 0); ErrorCount = $total; Path = $path; Environments = $results }
    }
    catch {
        Write-PpdfLog -Level error -Message $_.Exception.Message
        return New-PpdfResult -ExitCode 1 -Command 'validate' -Data @{ Error = $_.Exception.Message }
    }
}

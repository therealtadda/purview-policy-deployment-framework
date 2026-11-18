function Get-PpdfOrchestrator {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $url = if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) { "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)" }
        return [ordered]@{ name = 'github'; runId = $env:GITHUB_RUN_ID; runUrl = $url; commit = $env:GITHUB_SHA; actor = $env:GITHUB_ACTOR; ref = $env:GITHUB_REF }
    }
    if ($env:TF_BUILD -eq 'True') {
        $url = if ($env:SYSTEM_COLLECTIONURI -and $env:SYSTEM_TEAMPROJECT -and $env:BUILD_BUILDID) { "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_build/results?buildId=$($env:BUILD_BUILDID)" }
        return [ordered]@{ name = 'azure-devops'; runId = $env:BUILD_BUILDID; runUrl = $url; commit = $env:BUILD_SOURCEVERSION; actor = $env:BUILD_REQUESTEDFOR; ref = $env:BUILD_SOURCEBRANCH }
    }
    if ($env:TFC_RUN_ID) {
        return [ordered]@{ name = 'terraform-cloud'; runId = $env:TFC_RUN_ID; runUrl = $null; commit = $env:TFC_CONFIGURATION_VERSION_GIT_COMMIT_SHA; actor = $null; ref = $env:TFC_CONFIGURATION_VERSION_GIT_BRANCH }
    }
    $commit = $null
    try { if (Get-Command git -ErrorAction SilentlyContinue) { $commit = (& git rev-parse HEAD 2>$null) } } catch { $commit = $null }
    return [ordered]@{ name = 'local'; runId = [guid]::NewGuid().ToString(); runUrl = $null; commit = $commit; actor = [Environment]::UserName; ref = $null }
}

function Initialize-PpdfRun {
    param([string]$Command, [string]$OutputPath)
    if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) 'out' }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $script:Run = [ordered]@{
        id           = [guid]::NewGuid().ToString()
        command      = $Command
        startedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        orchestrator = Get-PpdfOrchestrator
        engine       = (Get-PpdfEngineVersion)
        outputPath   = (Resolve-Path $OutputPath).Path
        logPath      = (Join-Path (Resolve-Path $OutputPath).Path "ppdf-$Command.log.jsonl")
    }
    return $script:Run
}

function Get-PpdfEngineVersion {
    $manifest = Join-Path $script:ModuleRoot 'PurviewIaC.psd1'
    try { return [string](Import-PowerShellDataFile $manifest).ModuleVersion } catch { return '0.0.0' }
}

function Write-PpdfLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('debug', 'info', 'warn', 'error')][string]$Level = 'info',
        [hashtable]$Data
    )
    $entry = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); level = $Level; msg = $Message }
    if ($Data) { $entry.data = $Data }
    if ($script:Run -and $script:Run.logPath) {
        try { Add-Content -Path $script:Run.logPath -Value (ConvertTo-Json $entry -Depth 10 -Compress) -Encoding utf8NoBOM } catch { Write-Verbose "log write failed: $_" }
    }
    switch ($Level) {
        'debug' { Write-Verbose $Message }
        'warn' {
            Write-Warning $Message
            if ($env:GITHUB_ACTIONS -eq 'true') { Write-Information "::warning::$Message" }
            elseif ($env:TF_BUILD -eq 'True') { Write-Information "##vso[task.logissue type=warning]$Message" }
        }
        'error' {
            if ($env:GITHUB_ACTIONS -eq 'true') { Write-Information "::error::$Message" }
            elseif ($env:TF_BUILD -eq 'True') { Write-Information "##vso[task.logissue type=error]$Message" }
            else { Write-Information "ERROR: $Message" }
        }
        default { Write-Information $Message }
    }
}

function Set-PpdfOutput {
    <#
    .SYNOPSIS
    Publishes a named output value to the orchestrator (GitHub step outputs / ADO output variables).
    #>
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding utf8NoBOM }
    if ($env:TF_BUILD -eq 'True') {
        Write-Information "##vso[task.setvariable variable=$Name;isOutput=true]$Value"
        Write-Information "##vso[task.setvariable variable=$Name]$Value"
    }
}

function Add-PpdfSummary {
    <#
    .SYNOPSIS
    Appends markdown to the orchestrator job summary (GitHub step summary / ADO build summary attachment).
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($env:GITHUB_STEP_SUMMARY) { Get-Content -LiteralPath $Path -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM }
    if ($env:TF_BUILD -eq 'True') { Write-Information "##vso[task.uploadsummary]$((Resolve-Path $Path).Path)" }
}

function New-PpdfResult {
    param([int]$ExitCode, [string]$Command, [hashtable]$Data = @{})
    $r = [ordered]@{ Command = $Command; ExitCode = $ExitCode }
    foreach ($k in $Data.Keys) { $r[$k] = $Data[$k] }
    Set-PpdfOutput -Name 'ppdf_exit_code' -Value $ExitCode
    return [pscustomobject]$r
}

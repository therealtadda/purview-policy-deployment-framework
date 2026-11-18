function Get-PpdfRequiredService {
    param($Context)
    $s = @($script:ObjectTypes.Values | Where-Object { $_.Workload -in $Context.Workloads } | ForEach-Object { $_.Service } | Select-Object -Unique)
    if ($s.Count -eq 0) { $s = @('scc') }
    return $s
}

function Get-PpdfPlanExitCode {
    param($Plan)
    if ($Plan.summary.blocked -gt 0) { return 3 }
    if (@($Plan.actions).Count -gt 0) { return 2 }
    return 0
}

function Write-PpdfContextIssue {
    param($Context)
    foreach ($w in $Context.Warnings) { Write-PpdfLog -Level warn -Message $w }
    foreach ($e in $Context.Errors) { Write-PpdfLog -Level error -Message $e }
}

function Invoke-PpdfPlanCore {
    <#
    .SYNOPSIS
    Shared implementation for plan / promote / drift: builds and persists a plan document with orchestrator outputs.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Stage,
        [string]$SimulationReportPath,
        [string]$OutputPath,
        [string]$FileBase = 'plan'
    )
    Connect-PpdfIdentity -Role 'reader' -EnvSpec $Context.Env -Services (Get-PpdfRequiredService $Context)
    try { $result = Build-PpdfPlan -Context $Context -Stage $Stage -SimulationReportPath $SimulationReportPath }
    finally { Disconnect-PpdfIdentity }
    $plan = New-PpdfPlanDocument -Context $Context -Result $result -Stage $Stage -SimulationReportPath $SimulationReportPath
    $path = Join-Path $OutputPath "$FileBase.json"
    $hash = Save-PpdfDocument -Document $plan -Path $path
    $md = Join-Path $OutputPath "$FileBase.md"
    Set-Content -LiteralPath $md -Value (ConvertTo-PpdfPlanMarkdown -Plan $plan -Hash $hash) -Encoding utf8NoBOM
    Add-PpdfSummary -Path $md
    $exit = Get-PpdfPlanExitCode -Plan $plan
    Set-PpdfOutput -Name 'plan_path' -Value $path
    Set-PpdfOutput -Name 'plan_hash' -Value $hash
    Set-PpdfOutput -Name 'has_changes' -Value ([string](@($plan.actions).Count -gt 0)).ToLowerInvariant()
    Set-PpdfOutput -Name 'blocked' -Value ([string]($plan.summary.blocked -gt 0)).ToLowerInvariant()
    Set-PpdfOutput -Name 'approval_tier' -Value $plan.requiredApprovalTier
    Set-PpdfOutput -Name 'approval_environment' -Value $plan.approvalEnvironment
    Set-PpdfOutput -Name 'workloads' -Value ((@($plan.actions | ForEach-Object { $_.workload }) | Sort-Object -Unique) -join ',')
    $s = $plan.summary
    Write-PpdfLog -Message ("{0} [{1}/{2}]: create={3} update={4} adopt={5} delete={6} noop={7} blocked={8} deferred={9}; approval tier '{10}' -> '{11}'; hash {12}" -f $FileBase, $Context.EnvName, $Stage, $s.create, $s.update, $s.adopt, $s.delete, $s.noop, $s.blocked, $s.deferred, $plan.requiredApprovalTier, $plan.approvalEnvironment, $hash)
    return @{ Plan = $plan; Hash = $hash; Path = $path; MarkdownPath = $md; ExitCode = $exit }
}

function Invoke-PpdfSimulationReportCore {
    param([Parameter(Mandatory)]$Context, [string]$OutputPath)
    Connect-PpdfIdentity -Role 'reader' -EnvSpec $Context.Env -Services (Get-PpdfRequiredService $Context)
    try { $report = Build-PpdfSimulationReport -Context $Context }
    finally { Disconnect-PpdfIdentity }
    $path = Join-Path $OutputPath 'simulation-report.json'
    $hash = Save-PpdfDocument -Document $report -Path $path
    $md = Join-Path $OutputPath 'simulation-report.md'
    Set-Content -LiteralPath $md -Value (ConvertTo-PpdfSimulationMarkdown -Report $report -Hash $hash) -Encoding utf8NoBOM
    Add-PpdfSummary -Path $md
    Set-PpdfOutput -Name 'sim_report_path' -Value $path
    Set-PpdfOutput -Name 'sim_report_hash' -Value $hash
    Set-PpdfOutput -Name 'sim_pass' -Value ([string]$report.pass).ToLowerInvariant()
    foreach ($e in @($report.artifacts)) {
        $lvl = if ($e.status -in 'fail', 'missing', 'stale') { 'warn' } else { 'info' }
        Write-PpdfLog -Level $lvl -Message "simulation [$($e.id)]: $($e.status) $((@($e.notes) -join ' '))"
    }
    $exit = if ($report.pass) { 0 } else { 3 }
    return @{ Report = $report; Hash = $hash; Path = $path; ExitCode = $exit }
}

function Test-PpdfDocumentIntegrity {
    <#
    .SYNOPSIS
    Verifies a persisted document against its .sha256 sidecar and an optional externally supplied hash.
    #>
    param([string]$Path, [string]$ExpectedHash)
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Valid = $false; Hash = $null; Errors = @("File not found: $Path") } }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = "$Path.sha256"
    if (Test-Path -LiteralPath $sidecar) {
        $s = (Get-Content -LiteralPath $sidecar -Raw).Trim().Split(' ')[0].ToLowerInvariant()
        if ($s -ne $hash) { $errors.Add("Hash of $(Split-Path -Leaf $Path) does not match its .sha256 sidecar.") }
    }
    elseif (-not $ExpectedHash) { $errors.Add("No .sha256 sidecar and no expected hash supplied for $(Split-Path -Leaf $Path).") }
    if ($ExpectedHash -and $ExpectedHash.ToLowerInvariant() -ne $hash) { $errors.Add("Hash of $(Split-Path -Leaf $Path) ($hash) does not match the approved hash ($ExpectedHash).") }
    return @{ Valid = ($errors.Count -eq 0); Hash = $hash; Errors = $errors.ToArray() }
}

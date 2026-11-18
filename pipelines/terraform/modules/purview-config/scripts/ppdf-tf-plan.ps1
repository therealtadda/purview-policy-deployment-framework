#!/usr/bin/env pwsh

<#
.SYNOPSIS
Terraform "external" data source program: runs `ppdf plan` (or `promote`) and returns the result to Terraform.

.DESCRIPTION
Called by data.external.ppdf in the purview-config module during `terraform plan`; you do not normally run it by hand.

Protocol (hashicorp/external): Terraform writes a JSON object of strings to stdin and expects a single JSON object of
strings on stdout. Everything the PPDF CLI prints is therefore redirected to stderr, which Terraform shows in its log
(set TF_LOG=INFO or look at the run log in HCP Terraform).

Query keys: cli, command (plan|promote), environment, stage, config_root, output_path, artifacts and workloads
(comma-separated, optional).

Result keys: exit_code, plan_hash, has_changes, blocked, approval_tier, approval_environment, workloads,
summary (JSON), plan_markdown, plan_b64 (the exact plan.json bytes, base64-encoded, consumed by ppdf-tf-apply.ps1).

Identity: runs as the reader identity. In HCP Terraform the plan phase receives a workload identity token whose
subject ends in run_phase:plan, which only the reader app registration trusts.

Exit codes: 0 when PPDF produced a plan, including "changes pending" (PPDF exit 2) and "blocked" (PPDF exit 3);
Terraform turns those into a pending change or a failed precondition. 1 when PPDF failed, which fails `terraform plan`.

.EXAMPLE
'{"cli":"./ppdf/cli/ppdf.ps1","command":"plan","environment":"dev","stage":"auto","config_root":"./config","output_path":"./.ppdf/dev","artifacts":"","workloads":""}' | pwsh -NoProfile -File ./ppdf-tf-plan.ps1

Runs the same plan Terraform would and prints the result object. Use this when troubleshooting a failing data source.
#>
$ErrorActionPreference = 'Stop'
try {
    $q = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($q.command -notin 'plan', 'promote') { throw "Unsupported command '$($q.command)'." }
    $out = [string]$q.output_path
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $resultPath = Join-Path $out "tf-$($q.command)-result.json"
    Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue

    $cliArgs = @($q.command, '-Environment', $q.environment, '-OutputPath', $out)
    if ($q.config_root) { $cliArgs += @('-ConfigRoot', $q.config_root) }
    if ($q.command -eq 'plan' -and $q.stage) { $cliArgs += @('-Stage', $q.stage) }
    if ($q.artifacts) { $cliArgs += @('-Artifact', $q.artifacts) }
    if ($q.workloads) { $cliArgs += @('-Workload', $q.workloads) }

    $env:PPDF_RESULT_PATH = $resultPath
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoProfile -NonInteractive -File $q.cli @cliArgs 2>&1 | ForEach-Object { [Console]::Error.WriteLine([string]$_) }
    $code = $LASTEXITCODE
    if ($code -notin 0, 2, 3 -or -not (Test-Path -LiteralPath $resultPath)) { throw "ppdf $($q.command) failed (exit $code); see the log above." }

    $r = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if (-not $r.PlanPath) { throw "ppdf $($q.command) did not produce a plan (exit $code)." }
    $plan = Get-Content -LiteralPath $r.PlanPath -Raw | ConvertFrom-Json
    $mdPath = [System.IO.Path]::ChangeExtension($r.PlanPath, '.md')
    $actions = @($plan.actions)

    [ordered]@{
        exit_code            = [string]$code
        plan_hash            = [string]$r.PlanHash
        has_changes          = ([string]($actions.Count -gt 0)).ToLowerInvariant()
        blocked              = ([string]([int]$plan.summary.blocked -gt 0)).ToLowerInvariant()
        approval_tier        = [string]$plan.requiredApprovalTier
        approval_environment = [string]$plan.approvalEnvironment
        workloads            = (@($actions | ForEach-Object { $_.workload }) | Sort-Object -Unique) -join ','
        summary              = ($plan.summary | ConvertTo-Json -Compress)
        plan_markdown        = if (Test-Path -LiteralPath $mdPath) { Get-Content -LiteralPath $mdPath -Raw } else { '' }
        plan_b64             = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($r.PlanPath))
    } | ConvertTo-Json -Compress
    exit 0
}
catch {
    [Console]::Error.WriteLine("ppdf-tf-plan: $($_.Exception.Message)")
    exit 1
}

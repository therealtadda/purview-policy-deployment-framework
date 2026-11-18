#!/usr/bin/env pwsh

<#
.SYNOPSIS
Terraform local-exec program: applies the exact PPDF plan that was approved in the Terraform plan.

.DESCRIPTION
Called by terraform_data.apply in the purview-config module during `terraform apply`; you do not normally run it by hand.

The plan document travels inside the Terraform plan (base64, split across PPDF_TF_PLAN_B64_0000, _0001, ...). This
script reassembles the bytes, writes them to <output>/approved-plan.json and runs
`ppdf apply -ExpectedPlanHash <hash> -ApprovedTier <tier>`. Because the bytes and the hash both come from the reviewed
Terraform plan, a plan computed later (or tampered with) cannot be applied. Plan and apply may therefore run on
different machines, as they do in HCP Terraform.

Environment variables (set by the module):
  PPDF_TF_CLI            path to cli/ppdf.ps1
  PPDF_TF_HAS_CHANGES    'true' or 'false'; nothing is done when 'false'
  PPDF_TF_PLAN_HASH      SHA-256 the reviewer approved
  PPDF_TF_APPROVED_TIER  highest tier this workspace may apply
  PPDF_TF_OUTPUT_PATH    where apply-result.json and the evidence bundle are written
  PPDF_TF_WORKLOADS      optional comma-separated workload filter
  PPDF_TF_PLAN_B64_nnnn  base64 chunks of the plan document

Identity: runs as the deployer identities. In HCP Terraform the apply phase receives a token whose subject ends in
run_phase:apply, which only the deployer app registrations trust; PPDF connects as each workload's identity in turn.

Exit codes: passes through `ppdf apply`: 0 applied; 3 refused (for example a hash mismatch, or a plan older than
approvals.maxPlanAgeHours); 1 failed. Any non-zero exit fails `terraform apply` and leaves the resource tainted, so the
next run re-plans and needs approval again.

.EXAMPLE
terraform apply

The normal way to run this script. If it refuses because the plan is too old, run `terraform plan` again and have
the new plan approved.
#>
$ErrorActionPreference = 'Stop'
if ($env:PPDF_TF_HAS_CHANGES -ne 'true') {
    Write-Host 'PPDF: the tenant already matches the configuration; nothing to apply.'
    exit 0
}

$chunks = Get-ChildItem env: | Where-Object Name -like 'PPDF_TF_PLAN_B64_*' | Sort-Object Name | ForEach-Object Value
if (-not $chunks) { Write-Error 'PPDF: no plan content was passed from the Terraform plan.'; exit 1 }
$out = $env:PPDF_TF_OUTPUT_PATH
New-Item -ItemType Directory -Path $out -Force | Out-Null
$planPath = Join-Path $out 'approved-plan.json'
[System.IO.File]::WriteAllBytes($planPath, [Convert]::FromBase64String(($chunks -join '')))

$cliArgs = @('apply', '-PlanPath', $planPath, '-ExpectedPlanHash', $env:PPDF_TF_PLAN_HASH, '-ApprovedTier', $env:PPDF_TF_APPROVED_TIER, '-OutputPath', $out)
if ($env:PPDF_TF_WORKLOADS) { $cliArgs += @('-Workload', $env:PPDF_TF_WORKLOADS) }
$pwsh = (Get-Process -Id $PID).Path
& $pwsh -NoProfile -NonInteractive -File $env:PPDF_TF_CLI @cliArgs
exit $LASTEXITCODE

#!/usr/bin/env pwsh

<#
.SYNOPSIS
PPDF command line: one entry point for every pipeline (Azure DevOps, GitHub Actions, Terraform, or anything else).

.DESCRIPTION
Usage:
  pwsh ./cli/ppdf.ps1 <command> [-Parameter value ...]
  pwsh ./cli/ppdf.ps1 help <command>          full help for one command
  pwsh ./cli/ppdf.ps1 <command> --help        same

Each command calls the PurviewIaC module function shown, with the same parameters. Typical order:
validate -> plan (simulate) -> apply -> simulation-report -> promote -> apply -> drift.

  Command            Function                      Identity used      What it does
  validate           Invoke-PpdfValidate           none (offline)     Check config files against schemas and rules
  plan               Invoke-PpdfPlan               reader             Compare config with tenant; write plan.json/.md
  apply              Invoke-PpdfApply              dlp/retention/     Make the changes in an approved plan
                                                   classifier/rbac
  simulation-report  Invoke-PpdfSimulationReport   reader             Measure simulation results against thresholds
  promote            Invoke-PpdfPromote            reader             Plan simulate -> enforce for passing artifacts
  drift              Invoke-PpdfDrift              reader             Find portal edits / deletions since last apply
  export             Invoke-PpdfExport             reader             Write existing tenant config as artifact files
  rollback           Invoke-PpdfRollback           none (offline)     Build a plan that undoes a previous apply
  kinds              Get-PpdfKind                  none (offline)     List supported artifact kinds
  help               -                             -                  This text, or 'help <command>'

Argument rules:
  * Parameter names are case-insensitive and may use one or two dashes: -Environment dev, --environment dev.
  * Array parameters accept a comma-separated string: -Workload dlp,retention
  * Switches can be bare or take true/false (handy for pipeline variables): -UseExistingConnection false

Exit codes (all commands):
  0  success, nothing pending
  2  success, and there are changes (plan/promote/rollback) or drift (drift) to review
  3  stopped by a safety gate: blocked plan items, apply refused or stale, simulation gate failed
  1  error (invalid config, sign-in failure, cmdlet failure); see the log in the output folder

Environment variables:
  PPDF_CONFIG_ROOT       default for -ConfigRoot (otherwise ./config)
  PPDF_RESULT_PATH       also write the command result as JSON to this file (Plan/Report bodies omitted)
  PPDF_SKIP_CONNECT      1 = same as -UseExistingConnection
  PPDF_MODULE_PATH       PurviewIaC.psd1 to load (default ../src/PurviewIaC/PurviewIaC.psd1)
  PPDF_SCHEMA_PATH       folder with the JSON schemas (default: the repository's schemas/ folder)
  PPDF_YAMLDOTNET_PATH   YamlDotNet.dll to use if powershell-yaml is not installed (or use .json config)
  PPDF_FEDERATED_TOKEN, PPDF_CERT_THUMBPRINT, PPDF_CERT_PATH, PPDF_CERT_PASSWORD
                         credential overrides; see Get-Help about_PurviewIaC (IDENTITIES) and
                         docs/identities.md

Outputs for pipelines: on GitHub Actions and Azure DevOps each command also publishes outputs such as plan_path,
plan_hash, has_changes, approval_tier and ppdf_exit_code (see each command's help, OUTPUTS/NOTES). Every run
writes a JSON-lines log to <OutputPath>/ppdf-<command>.log.jsonl.

Prerequisites: PowerShell 7.4+ and powershell-yaml (or PPDF_YAMLDOTNET_PATH). Commands that contact the tenant
also need ExchangeOnlineManagement 3.8+ and Microsoft.Graph.Authentication 2.x; validate, rollback and kinds do
not.

.PARAMETER Command
The command to run (see the table above). Default: help.

.PARAMETER Arguments
Parameters for the command, in -Name value form.

.EXAMPLE
pwsh ./cli/ppdf.ps1 validate -ConfigRoot ./config

Offline check of every environment. Run it on every pull request.

.EXAMPLE
pwsh ./cli/ppdf.ps1 plan -Environment dev -Stage simulate -OutputPath ./out/dev

Plans dev in simulation mode and writes ./out/dev/plan.md for review.

.EXAMPLE
pwsh ./cli/ppdf.ps1 apply -PlanPath ./out/dev/plan.json -ExpectedPlanHash 3f2a... -ApprovedTier standard -OutputPath ./out/dev

Applies the reviewed plan.

.EXAMPLE
pwsh ./cli/ppdf.ps1 simulation-report -Environment prod -OutputPath ./out/sim

Checks whether simulated artifacts are ready to enforce (exit 0) or not yet (exit 3).

.EXAMPLE
pwsh ./cli/ppdf.ps1 rollback -PlanPath ./evidence/plan.json -ApplyResultPath ./apply-dlp/apply-result.json,./apply-retention/apply-result.json -OutputPath ./out/rollback

Builds rollback-plan.json from a previous apply's evidence (several apply results when the plan was applied per
workload). Exit 2 means there is something to undo; approve (elevated or higher) and apply it like any plan.
In the example pipelines, use the 'rollback' command with the run ID instead.

.EXAMPLE
pwsh ./cli/ppdf.ps1 help apply

Full help for the apply command, including all parameters and examples.

.LINK
https://github.com/therealtadda/purview-policy-deployment-framework
#>
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments)][object[]]$Arguments
)
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$modulePath = if ($env:PPDF_MODULE_PATH) { $env:PPDF_MODULE_PATH } else { Join-Path $PSScriptRoot '..\src\PurviewIaC\PurviewIaC.psd1' }
Import-Module $modulePath -Force

$map = @{
    'validate'          = 'Invoke-PpdfValidate'
    'plan'              = 'Invoke-PpdfPlan'
    'simulation-report' = 'Invoke-PpdfSimulationReport'
    'promote'           = 'Invoke-PpdfPromote'
    'apply'             = 'Invoke-PpdfApply'
    'drift'             = 'Invoke-PpdfDrift'
    'export'            = 'Invoke-PpdfExport'
    'rollback'          = 'Invoke-PpdfRollback'
    'kinds'             = 'Get-PpdfKind'
}
$helpTokens = @('help', '-h', '--help', '-help')

$helpTarget = $null
if ($Command -in $helpTokens -and @($Arguments).Count) { $helpTarget = [string]@($Arguments)[0] }
elseif ($map.ContainsKey($Command) -and @($Arguments | Where-Object { [string]$_ -in $helpTokens }).Count) { $helpTarget = $Command }
if ($helpTarget) {
    if (-not $map.ContainsKey($helpTarget)) { Write-Error -Message "Unknown command '$helpTarget'. Run 'ppdf.ps1 help' for the list." -ErrorAction Continue; exit 1 }
    Get-Help $map[$helpTarget] -Full | Out-String | Write-Information
    exit 0
}

if (-not $map.ContainsKey($Command)) {
    if ($Command -notin $helpTokens) { Write-Error -Message "Unknown command '$Command'." -ErrorAction Continue }
    Get-Help $PSCommandPath -Detailed | Out-String | Write-Information
    exit $(if ($Command -in $helpTokens) { 0 } else { 1 })
}

# Convert "-Name value -Switch" style remaining arguments into a splat table.
$splat = @{}
$cmd = Get-Command $map[$Command]
$i = 0
$argList = @($Arguments)
while ($i -lt $argList.Count) {
    $token = [string]$argList[$i]
    if ($token -notmatch '^-{1,2}(?<n>[A-Za-z][A-Za-z0-9]*):?$') { throw "Unexpected argument '$token'." }
    $name = $Matches.n
    $p = $cmd.Parameters.Values | Where-Object { $_.Name -eq $name -or $_.Aliases -contains $name } | Select-Object -First 1
    if (-not $p) { throw "Unknown parameter '-$name' for '$Command'. Valid: $(($cmd.Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters }) -join ', ')" }
    if ($p.ParameterType -eq [switch]) {
        $next = if ($i + 1 -lt $argList.Count) { [string]$argList[$i + 1] } else { $null }
        if ($next -in 'true', 'false', '$true', '$false') { $splat[$p.Name] = $next -match 'true'; $i += 2 } else { $splat[$p.Name] = $true; $i++ }
        continue
    }
    if ($i + 1 -ge $argList.Count) { throw "Missing value for '-$name'." }
    $value = $argList[$i + 1]
    if ($p.ParameterType.IsArray -and $value -is [string]) { $value = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $splat[$p.Name] = $value
    $i += 2
}

if ($Command -eq 'kinds') { & $cmd @splat | Format-Table -AutoSize | Out-String | Write-Information; exit 0 }

$result = & $cmd @splat
if ($result.PSObject.Properties['Error'] -and $result.Error) { Write-Error -Message $result.Error -ErrorAction Continue }
if ($env:PPDF_RESULT_PATH) {
    # Machine-readable result for wrappers (e.g. Terraform external data source) without parsing logs.
    $out = [ordered]@{}
    foreach ($prop in $result.PSObject.Properties) { if ($prop.Name -notin 'Plan', 'Report') { $out[$prop.Name] = $prop.Value } }
    ConvertTo-Json -InputObject $out -Depth 20 | Set-Content -LiteralPath $env:PPDF_RESULT_PATH -Encoding utf8NoBOM
}
exit [int]$result.ExitCode

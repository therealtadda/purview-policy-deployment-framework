#Requires -Version 7.2

<#
.SYNOPSIS
Creates the PPDF purpose-specific Entra identities (one app per role) with Microsoft Graph PowerShell.

.DESCRIPTION
Step 1 of 2 for setting up PPDF identities without Terraform (identities/terraform does the same thing as code; prefer
it if you already manage Entra with Terraform). Step 2 is Grant-PpdfPurviewRoles.ps1, which gives each identity its
Purview permissions.

For each role in -Roles the script creates, or leaves unchanged if it already exists:
  - an app registration "<NamePrefix>-<role>" and its service principal, with no client secret;
  - the Exchange.ManageAsApp application permission, which lets the app sign in to Security & Compliance PowerShell
    but grants no Purview rights by itself;
  - Microsoft Graph application permissions, only where needed:
      reader  RoleEligibilitySchedule.Read.Directory, RoleAssignmentSchedule.Read.Directory
      rbac    RoleEligibilitySchedule.ReadWrite.Directory, RoleAssignmentSchedule.ReadWrite.Directory
      others  none
  - federated identity credentials, so the pipeline signs in with its own OIDC token instead of a secret;
  - with -CreateApproverGroups, security groups "<NamePrefix>-approvers-<role>" and "<NamePrefix>-approvers-prod" to
    use as approvers in your orchestrator.

The script is idempotent: re-run it to add roles or trusts. It never removes anything and does not update an existing
app's permissions; fix those in the portal or delete the app and re-run.

When it finishes it:
  - writes -GrantFile (input for Grant-PpdfPurviewRoles.ps1); and
  - prints the spec.identities block to paste into config/environments/<env>.yml.

Which identity type to use (details in docs/identities.md):
  - GitHub-hosted or Azure DevOps-hosted agents, HCP Terraform: app + federated credential (this script).
  - Self-hosted runners in Azure: app + federated credential trusting a user-assigned managed identity
    (authMode managedidentity-fic), via -FederatedCredentialsFile.
  - No OIDC available: app + certificate from Key Vault (authMode certificate). Add the certificate yourself.
  - Autonomous read-only agents: identities/agent-id/New-PpdfAgentIdentities.ps1.

.PARAMETER NamePrefix
Prefix for app, role group and approver group names, for example ppdf-prod. Lower case letters, digits and dashes.
Use one prefix per tenant/environment so that identities are never shared across environments.

.PARAMETER TenantId
Entra tenant ID. Used to sign in to Microsoft Graph if no Graph session is open.

.PARAMETER Roles
Which identities to create. Default: all five. reader is required by every environment; create only the deployers
for workloads the environment manages (spec.workloads).

.PARAMETER FederatedCredentialsFile
JSON file with an array of trusts to add, for any orchestrator:
  [ { "role": "dlp", "name": "ado-prod-dlp",
      "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
      "subject": "<copied from the Azure DevOps service connection>" } ]
audiences is optional (default api://AzureADTokenExchange). Common issuer/subject pairs:
  Azure DevOps      issuer and subject shown on the workload identity service connection
                    (use the "Manually" option when creating it)
  HCP Terraform     issuer https://app.terraform.io, subject
                    organization:<org>:project:<project>:workspace:<ws>:run_phase:apply (and one for plan)
  Managed identity  issuer https://login.microsoftonline.com/<tenant-id>/v2.0, subject <UAMI principal id>
Entra allows at most 20 federated credentials per app.

.PARAMETER GitHubRepository
owner/repo. Shortcut that adds GitHub Actions OIDC trusts bound to GitHub environments, so only jobs that passed that
environment's approval can obtain a token:
  reader     environment "<ApprovalPrefix>-read"
  deployers  environments "<ApprovalPrefix>-low", "-standard", "-elevated" and "-critical"
Create those environments in the repository (Settings > Environments) with matching required reviewers.

.PARAMETER ApprovalPrefix
First part of the GitHub environment names used by -GitHubRepository. Default prod. Should match the environment's
approvals.pattern in PPDF config (for example "prod-{tier}").

.PARAMETER CreateApproverGroups
Also create the approver security groups described above. Membership is left to you.

.PARAMETER GrantFile
Where to write the grant file for Grant-PpdfPurviewRoles.ps1. Default ./ppdf-grant.json. It contains app and object
IDs only, no secrets.

.PARAMETER GraphEnvironment
Microsoft Graph cloud: Global (default), USGov (GCC High) or USGovDoD.

.INPUTS
None.

.OUTPUTS
None. Writes -GrantFile and prints next steps and the spec.identities block.

.NOTES
Requires PowerShell 7.2+ and Microsoft.Graph.Authentication.
Run as Application Administrator (or Cloud Application Administrator) to create apps and Privileged Role
Administrator to grant Graph application permissions. The script requests the Graph scopes Application.ReadWrite.All,
AppRoleAssignment.ReadWrite.All and Group.ReadWrite.All. To use a different session, run Connect-MgGraph first.
Supports -WhatIf and -Confirm. With -WhatIf nothing is created, so the grant file is not written.

.EXAMPLE
./New-PpdfIdentities.ps1 -NamePrefix ppdf-prod -TenantId 00000000-0000-0000-0000-000000000000 -WhatIf

Shows what would be created for all five roles without changing anything.

.EXAMPLE
./New-PpdfIdentities.ps1 -NamePrefix ppdf-prod -TenantId 00000000-0000-0000-0000-000000000000 `
    -GitHubRepository contoso/purview-config -ApprovalPrefix prod -GrantFile ./grant.json
./Grant-PpdfPurviewRoles.ps1 -InputFile ./grant.json -Organization contoso.onmicrosoft.com

Creates the identities trusted by GitHub environments prod-read and prod-low ... prod-critical, then grants their
Purview roles.

.EXAMPLE
./New-PpdfIdentities.ps1 -NamePrefix ppdf-dev -TenantId 00000000-0000-0000-0000-000000000000 `
    -Roles reader, dlp -FederatedCredentialsFile ./ado-trusts.json

Creates only the reader and DLP identities for an Azure DevOps-driven dev environment, using the trusts in the file.

.LINK
https://github.com/therealtadda/purview-policy-deployment-framework/blob/main/docs/identities.md
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'FederatedCredentialsFile', Justification = 'Path to a JSON file of federated credential subjects; contains no secrets.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,30}$')][string]$NamePrefix,
    [Parameter(Mandatory)][string]$TenantId,
    [ValidateSet('reader', 'dlp', 'retention', 'classifier', 'rbac')][string[]]$Roles = @('reader', 'dlp', 'retention', 'classifier', 'rbac'),
    [string]$FederatedCredentialsFile,
    [string]$GitHubRepository,
    [string]$ApprovalPrefix = 'prod',
    [switch]$CreateApproverGroups,
    [string]$GrantFile = './ppdf-grant.json',
    [ValidateSet('Global', 'USGov', 'USGovDoD')][string]$GraphEnvironment = 'Global'
)

$ErrorActionPreference = 'Stop'
$exchangeAppId = '00000002-0000-0ff1-ce00-000000000000'
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphPermissions = @{
    reader     = @('RoleEligibilitySchedule.Read.Directory', 'RoleAssignmentSchedule.Read.Directory')
    dlp        = @()
    retention  = @()
    classifier = @()
    rbac       = @('RoleEligibilitySchedule.ReadWrite.Directory', 'RoleAssignmentSchedule.ReadWrite.Directory')
}
$descriptions = @{
    reader     = 'Read-only: plan, simulation reports, drift and export. Never writes.'
    dlp        = 'Writes DLP policies and rules only.'
    retention  = 'Writes retention policies, rules and retention labels only.'
    classifier = 'Writes custom sensitive information type rule packages only.'
    rbac       = 'Writes Purview role groups and requests Entra PIM eligibility (allowlisted roles) only.'
}

function Get-Single([string]$Uri) {
    $r = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType HashTable
    return @($r.value)[0]
}

function Get-Fic {
    $list = [System.Collections.Generic.List[hashtable]]::new()
    if ($FederatedCredentialsFile) {
        foreach ($c in (Get-Content -LiteralPath $FederatedCredentialsFile -Raw | ConvertFrom-Json -AsHashtable)) { $list.Add($c) }
    }
    if ($GitHubRepository) {
        foreach ($r in $Roles) {
            $envs = if ($r -eq 'reader') { @("$ApprovalPrefix-read") } else { 'low', 'standard', 'elevated', 'critical' | ForEach-Object { "$ApprovalPrefix-$_" } }
            foreach ($e in $envs) {
                $list.Add(@{ role = $r; name = "github-$e"; issuer = 'https://token.actions.githubusercontent.com'; subject = "repo:${GitHubRepository}:environment:$e" })
            }
        }
    }
    return $list
}

if (-not (Get-MgContext)) {
    Connect-MgGraph -TenantId $TenantId -Environment $GraphEnvironment -NoWelcome -Scopes @(
        'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Group.ReadWrite.All')
}

$exchangeSp = Get-Single "v1.0/servicePrincipals?`$filter=appId eq '$exchangeAppId'"
$graphSp = Get-Single "v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'"
$manageAsApp = ($exchangeSp.appRoles | Where-Object value -EQ 'Exchange.ManageAsApp').id
if (-not $manageAsApp) { throw 'Exchange.ManageAsApp app role not found on the Office 365 Exchange Online service principal.' }

$fics = Get-Fic
$grant = [ordered]@{}
$envBlock = [System.Text.StringBuilder]::new()

foreach ($role in $Roles) {
    $name = "$NamePrefix-$role"
    $graphRoleIds = @(foreach ($p in $graphPermissions[$role]) {
            $id = ($graphSp.appRoles | Where-Object value -EQ $p).id
            if (-not $id) { throw "Graph permission '$p' not found." }
            $id
        })

    $app = Get-Single "v1.0/applications?`$filter=displayName eq '$name'"
    if (-not $app -and $PSCmdlet.ShouldProcess($name, 'Create application')) {
        $rra = @(@{ resourceAppId = $exchangeAppId; resourceAccess = @(@{ id = $manageAsApp; type = 'Role' }) })
        if ($graphRoleIds) { $rra += @{ resourceAppId = $graphAppId; resourceAccess = @($graphRoleIds | ForEach-Object { @{ id = $_; type = 'Role' } }) } }
        $app = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/applications' -OutputType HashTable -Body (@{
                displayName = $name; description = $descriptions[$role]; signInAudience = 'AzureADMyOrg'
                notes = 'Managed by PPDF New-PpdfIdentities.ps1. Purpose-specific Purview deployment identity.'
                tags = @('ppdf', "ppdf-role:$role"); requiredResourceAccess = $rra
            } | ConvertTo-Json -Depth 10)
    }
    if (-not $app) { continue } # -WhatIf

    $sp = Get-Single "v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'"
    if (-not $sp -and $PSCmdlet.ShouldProcess($name, 'Create service principal')) {
        $sp = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/servicePrincipals' -OutputType HashTable -Body (@{
                appId = $app.appId; appRoleAssignmentRequired = $true; tags = @('ppdf', "ppdf-role:$role") } | ConvertTo-Json)
    }
    if (-not $sp) { continue }

    $existing = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -OutputType HashTable).value)
    $wanted = @(@{ resourceId = $exchangeSp.id; appRoleId = $manageAsApp }) + @($graphRoleIds | ForEach-Object { @{ resourceId = $graphSp.id; appRoleId = $_ } })
    foreach ($w in $wanted) {
        if ($existing | Where-Object { $_.resourceId -eq $w.resourceId -and $_.appRoleId -eq $w.appRoleId }) { continue }
        if ($PSCmdlet.ShouldProcess($name, "Grant app role $($w.appRoleId)")) {
            Invoke-MgGraphRequest -Method POST -Uri "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -Body (@{
                    principalId = $sp.id; resourceId = $w.resourceId; appRoleId = $w.appRoleId } | ConvertTo-Json) | Out-Null
        }
    }

    $haveFic = @((Invoke-MgGraphRequest -Method GET -Uri "v1.0/applications/$($app.id)/federatedIdentityCredentials" -OutputType HashTable).value)
    foreach ($c in @($fics | Where-Object { $_.role -eq $role })) {
        if ($haveFic | Where-Object { $_.issuer -eq $c.issuer -and $_.subject -eq $c.subject }) { continue }
        if ($PSCmdlet.ShouldProcess($name, "Add federated credential $($c.subject)")) {
            $aud = if ($c.audiences) { @($c.audiences) } else { @('api://AzureADTokenExchange') }
            Invoke-MgGraphRequest -Method POST -Uri "v1.0/applications/$($app.id)/federatedIdentityCredentials" -Body (@{
                    name = ($c.name -replace '[^A-Za-z0-9\-_]', '-'); issuer = $c.issuer; subject = $c.subject; audiences = $aud } | ConvertTo-Json) | Out-Null
        }
    }

    $grant[$role] = [ordered]@{ appId = $app.appId; objectId = $sp.id; displayName = $name; roleGroup = ('{0}_{1}' -f ($NamePrefix -replace '-', '_').ToUpperInvariant(), $role.ToUpperInvariant()) }
    [void]$envBlock.AppendLine(('    {0}: {{ clientId: {1} }}' -f $role, $app.appId))
}

if ($CreateApproverGroups) {
    foreach ($g in @($Roles | Where-Object { $_ -ne 'reader' }) + 'prod') {
        $gName = "$NamePrefix-approvers-$g"
        if (Get-Single "v1.0/groups?`$filter=displayName eq '$gName'") { continue }
        if ($PSCmdlet.ShouldProcess($gName, 'Create approver group')) {
            Invoke-MgGraphRequest -Method POST -Uri 'v1.0/groups' -Body (@{
                    displayName = $gName; mailEnabled = $false; securityEnabled = $true
                    mailNickname = ($gName -replace '[^A-Za-z0-9]', ''); description = "PPDF $g approvers" } | ConvertTo-Json) | Out-Null
        }
    }
}

if ($grant.Count) {
    $grant | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $GrantFile -Encoding utf8
    Write-Host "Grant file written to $GrantFile. Next: ./Grant-PpdfPurviewRoles.ps1 -InputFile $GrantFile -Organization <tenant>.onmicrosoft.com"
    Write-Host "`nPaste into environments/<env>.yml:`n  identities:"
    Write-Host $envBlock.ToString()
}

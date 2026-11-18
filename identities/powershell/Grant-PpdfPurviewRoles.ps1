#Requires -Version 7.2

<#
.SYNOPSIS
Gives each PPDF identity its Purview permissions: registers it in Security & Compliance and adds it to its own
least-privilege custom role group.

.DESCRIPTION
Step 2 of 2 for setting up PPDF identities. Step 1 (identities/terraform or New-PpdfIdentities.ps1) creates the Entra
apps with Exchange.ManageAsApp, which lets them sign in to Security & Compliance PowerShell but grants no Purview
rights. Purview rights come only from role group membership, which neither Terraform nor Graph can manage, so this
script does it.

For each identity in -InputFile it:
  1. registers the app as a service principal in Security & Compliance (New-ServicePrincipal);
  2. creates a custom role group named after "roleGroup" containing only the roles for that identity;
  3. adds the service principal to the role group (Add-RoleGroupMember).

Roles granted (keep in sync with identities/roles-matrix.yml):
  reader      View-Only DLP Compliance Management, View-Only Retention Management, View-Only Record Management,
              View-Only Manage Alerts, Data Classification List Viewer
  dlp         DLP Compliance Management
  retention   Retention Management (+ Record Management with -IncludeRecordManagement)
  classifier  DLP Compliance Management (custom sensitive information types)
  rbac        Role Management
Role names marked "verify" in roles-matrix.yml should be checked in your tenant with Get-ManagementRole before
production use.

Safety:
  - Identities are never added to built-in role groups such as Compliance Administrator or Organization Management.
  - If the role group already exists, its roles are compared, never changed. Missing roles and roles beyond least
    privilege are reported as warnings for you to fix.
  - Re-running is safe; existing registrations and memberships are left as they are.

.PARAMETER InputFile
The grant file. Produce it with one of:
  terraform output -json grant_input > grant.json   (identities/terraform)
  New-PpdfIdentities.ps1 -GrantFile grant.json
  New-PpdfAgentIdentities.ps1 -GrantPurviewRead -GrantFile agent-grant.json
Format:
  { "<role>": { "appId": "...", "objectId": "<service principal object id>", "displayName": "...",
                "roleGroup": "...", "template": "reader" } }
<role> is reader, dlp, retention, classifier or rbac. template is optional; only "reader" may be used, and it gives a
differently named identity (for example an agent) the reader roles in its own role group. The full
"terraform output -json" document (with a grant_input key) is also accepted.

.PARAMETER Organization
Tenant primary domain, for example contoso.onmicrosoft.com. Passed to Connect-IPPSSession.

.PARAMETER IncludeRecordManagement
Also give the retention identity the Record Management role. Needed only if your retention labels declare items as
records or regulatory records.

.PARAMETER UseExistingSession
Do not call Connect-IPPSSession; use the Security & Compliance session that is already open.

.PARAMETER ExchangeEnvironmentName
Cloud for Connect-IPPSSession: O365Default (default), O365USGovGCCHigh or O365USGovDoD.

.INPUTS
None.

.OUTPUTS
None. Prints a table of identity, role group and roles.

.NOTES
Requires PowerShell 7.2+ and ExchangeOnlineManagement 3.2+.
Run interactively as a person with the Role Management role in Purview (for example, activate Compliance
Administrator or Organization Management through PIM for this task). Do not run it from a pipeline: no PPDF
identity is allowed to grant itself permissions.
Supports -WhatIf and -Confirm. Role group changes can take up to an hour to take effect.
Check the result with: Get-RoleGroupMember -Identity <roleGroup>, then run "ppdf plan" with the reader identity.

.EXAMPLE
terraform -chdir=identities/terraform/examples/github output -json grant_input > grant.json
./identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile grant.json -Organization contoso.onmicrosoft.com -WhatIf

Shows what would be registered, created and added, without changing anything.

.EXAMPLE
./identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile grant.json -Organization contoso.onmicrosoft.com -IncludeRecordManagement

Grants all identities in the file, giving the retention identity Record Management as well.

.EXAMPLE
Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
./identities/powershell/Grant-PpdfPurviewRoles.ps1 -InputFile agent-grant.json -Organization contoso.onmicrosoft.com -UseExistingSession

Grants read-only access to agent identities, reusing an open session.

.LINK
https://github.com/therealtadda/purview-policy-deployment-framework/blob/main/docs/identities.md
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][string]$Organization,
    [switch]$IncludeRecordManagement,
    [switch]$UseExistingSession,
    [ValidateSet('O365Default', 'O365USGovGCCHigh', 'O365USGovDoD')][string]$ExchangeEnvironmentName = 'O365Default'
)

$ErrorActionPreference = 'Stop'

# Keep in sync with identities/roles-matrix.yml. Roles marked "verify" there should be confirmed in your tenant
# (Get-ManagementRole) before production use.
$roleMap = @{
    reader     = @('View-Only DLP Compliance Management', 'View-Only Retention Management', 'View-Only Record Management', 'View-Only Manage Alerts', 'Data Classification List Viewer')
    dlp        = @('DLP Compliance Management')
    retention  = @('Retention Management')
    classifier = @('DLP Compliance Management')
    rbac       = @('Role Management')
}
if ($IncludeRecordManagement) { $roleMap.retention += 'Record Management' }

$descriptions = @{
    reader     = 'PPDF reader: plan, simulation reports, drift and export. Read-only.'
    dlp        = 'PPDF DLP deployer: DLP policies and rules.'
    retention  = 'PPDF retention deployer: retention policies, rules and labels.'
    classifier = 'PPDF classifier deployer: custom sensitive information type rule packages.'
    rbac       = 'PPDF RBAC deployer: Purview role groups.'
}

$grant = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json -AsHashtable
# terraform output -json <name> emits the value directly; accept the full "terraform output -json" shape too.
if ($grant.ContainsKey('grant_input')) { $grant = $grant.grant_input.value }

if (-not $UseExistingSession) {
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) { throw 'Install-Module ExchangeOnlineManagement -MinimumVersion 3.2 first.' }
    Connect-IPPSSession -Organization $Organization -ExchangeEnvironmentName $ExchangeEnvironmentName -ShowBanner:$false
}

$results = foreach ($role in $grant.Keys | Sort-Object) {
    $id = $grant[$role]
    # Optional "template" reuses another role's least-privilege set (agent identities use template "reader").
    $template = if ($id.template) { [string]$id.template } else { $role }
    if (-not $roleMap.ContainsKey($template)) { Write-Warning "Unknown role '$template' for '$role' skipped."; continue }
    if ($template -ne 'reader' -and $id.template) { throw "Only the 'reader' template may be reused ('$role' requested '$template')." }
    foreach ($k in 'appId', 'objectId', 'displayName', 'roleGroup') {
        if (-not $id[$k]) { throw "grant input for '$role' is missing '$k'." }
    }

    # 1. Service principal registration in Security & Compliance.
    $sp = Get-ServicePrincipal -Identity $id.objectId -ErrorAction SilentlyContinue
    if (-not $sp -and $PSCmdlet.ShouldProcess($id.displayName, 'New-ServicePrincipal')) {
        $sp = New-ServicePrincipal -AppId $id.appId -ObjectId $id.objectId -DisplayName $id.displayName
    }

    # 2. Dedicated custom role group (roles of an existing group are compared, never silently widened).
    $wanted = $roleMap[$template]
    $rg = Get-RoleGroup -Identity $id.roleGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
        if ($PSCmdlet.ShouldProcess($id.roleGroup, "New-RoleGroup with roles: $($wanted -join ', ')")) {
            $desc = if ($descriptions.ContainsKey($role)) { $descriptions[$role] } else { "PPDF $role (read-only, $template roles)." }
            $rg = New-RoleGroup -Name $id.roleGroup -Roles $wanted -Description $desc
        }
    }
    else {
        $have = @($rg.Roles | ForEach-Object { ($_ -split '\\')[-1] })
        $missing = @($wanted | Where-Object { $_ -notin $have })
        $extra = @($have | Where-Object { $_ -notin $wanted })
        if ($missing) { Write-Warning "Role group '$($id.roleGroup)' is missing roles: $($missing -join ', '). Recreate it or add the role assignment manually." }
        if ($extra) { Write-Warning "Role group '$($id.roleGroup)' has roles beyond least privilege: $($extra -join ', ')." }
    }

    # 3. Membership.
    $members = @(Get-RoleGroupMember -Identity $id.roleGroup -ErrorAction SilentlyContinue)
    $isMember = $members | Where-Object { $_.ExternalDirectoryObjectId -eq $id.objectId -or $_.Name -eq $id.objectId -or $_.DisplayName -eq $id.displayName }
    if (-not $isMember -and $PSCmdlet.ShouldProcess($id.roleGroup, "Add-RoleGroupMember $($id.displayName)")) {
        Add-RoleGroupMember -Identity $id.roleGroup -Member $id.objectId
    }

    [pscustomobject]@{ Role = $role; ServicePrincipal = $id.displayName; RoleGroup = $id.roleGroup; Roles = ($wanted -join ', ') }
}

$results | Format-Table -AutoSize
Write-Host 'Done. Validate with: Get-RoleGroupMember -Identity <group>, then run "ppdf plan" with the reader identity.'

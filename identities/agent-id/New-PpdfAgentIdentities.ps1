#Requires -Version 7.2

<#
.SYNOPSIS
Provisions Microsoft Entra Agent ID identities for PPDF's autonomous helper agents (read-only, propose-only).

.DESCRIPTION
Creates, idempotently:
  1. an agent identity blueprint "<Prefix>-agents" (the template/credential holder for all PPDF agents) with sponsors,
  2. the blueprint principal in the tenant,
  3. a federated identity credential on the blueprint trusting a user-assigned managed identity (where the agent runs),
     so no secret or certificate exists,
  4. agent identities "<Prefix>-sim-analyst" and "<Prefix>-drift-agent", each with sponsors (accountable humans),
  5. optionally (-GrantPurviewRead), Exchange.ManageAsApp + Graph read permissions on each agent identity and a grant
     file for Grant-PpdfPurviewRoles.ps1 (template "reader", own role group).

Least privilege by design: by default the agents receive NO Purview permissions. They consume the simulation report and
drift artifacts produced by the pipeline's reader identity and post summaries / open pull requests through the code host.
Deployment always happens through the pipeline with human approval. Use -GrantPurviewRead only if an agent must query
Purview directly.

The agent runtimes themselves are Phase 3 of the framework; this script provisions identities only.

Microsoft Entra Agent ID is in preview. Endpoints used (Microsoft Learn, verify before production):
  POST /v1.0/applications/microsoft.graph.agentIdentityBlueprint            (AgentIdentityBlueprint.Create)
  POST /v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal (AgentIdentityBlueprintPrincipal.Create)
  POST /v1.0/applications/{id}/federatedIdentityCredentials                (AgentIdentityBlueprint.AddRemoveCreds.All)
  POST /beta/servicePrincipals/microsoft.graph.agentIdentity                (AgentIdentity.Create.All)
Caller: Agent ID Administrator (or Agent ID Developer for blueprints they own) + Privileged Role Administrator when
-GrantPurviewRead grants application permissions.

When to use an agent identity rather than an app registration:
  - Use agent identities for autonomous software (AI agents) that act without a human starting each run, so that
    they are inventoried, sponsored by accountable people and governed separately from pipelines.
  - Keep pipeline deployers (dlp, retention, classifier, rbac) as app registrations with federated credentials;
    they run only after human approval. See docs/identities.md.

.PARAMETER TenantId
Entra tenant ID. Used for the managed identity trust and to sign in to Microsoft Graph if no session is open.

.PARAMETER Prefix
Name prefix. Creates blueprint "<Prefix>-agents" and agents "<Prefix>-<agent>". Default ppdf.

.PARAMETER SponsorUserIds
Object IDs of users accountable for the agents. Required: every agent must have a human sponsor.

.PARAMETER SponsorGroupIds
Object IDs of groups that also sponsor the agents.

.PARAMETER OwnerUserIds
Object IDs of users who can manage the blueprint (credentials and settings).

.PARAMETER ManagedIdentityPrincipalId
Principal (object) ID of the user-assigned managed identity on the host where the agents run. The blueprint trusts it
through a federated credential, so no secret or certificate is needed.

.PARAMETER Agents
Agent names to create. Default sim-analyst (summarises simulation reports) and drift-agent (reports drift and
proposes config changes as pull requests).

.PARAMETER GrantPurviewRead
Also give each agent Exchange.ManageAsApp and Graph read permissions and write -GrantFile, so that
Grant-PpdfPurviewRoles.ps1 can give them the reader roles in a shared role group "<PREFIX>_AGENTS_READ". Leave it off
unless an agent must query Purview itself.

.PARAMETER GrantFile
Where to write the grant file when -GrantPurviewRead is used. Default ./ppdf-agent-grant.json.

.INPUTS
None.

.OUTPUTS
None. Prints a table of agent name, client ID, object ID and blueprint app ID.

.NOTES
Requires PowerShell 7.2+ and Microsoft.Graph.Authentication. Supports -WhatIf and -Confirm; with -WhatIf the script
stops after reporting that the blueprint would be created, if it does not exist yet.
Agents never get write permissions from this script. If an agent needs a change made, it opens a pull request and
the normal pipeline, with human approval, deploys it.

.EXAMPLE
./New-PpdfAgentIdentities.ps1 -TenantId 00000000-0000-0000-0000-000000000000 `
    -SponsorUserIds 00000000-0000-0000-0000-000000000001 -ManagedIdentityPrincipalId 00000000-0000-0000-0000-000000000002 -WhatIf

Shows what would be created without changing anything.

.EXAMPLE
./New-PpdfAgentIdentities.ps1 -TenantId 00000000-0000-0000-0000-000000000000 `
    -SponsorUserIds 00000000-0000-0000-0000-000000000001 -ManagedIdentityPrincipalId 00000000-0000-0000-0000-000000000002 `
    -GrantPurviewRead -GrantFile ./agent-grant.json
../powershell/Grant-PpdfPurviewRoles.ps1 -InputFile ./agent-grant.json -Organization contoso.onmicrosoft.com

Creates both agents with read access to Purview, then grants the reader roles.

.LINK
https://github.com/therealtadda/purview-policy-deployment-framework/blob/main/docs/identities.md
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,30}$')][string]$Prefix = 'ppdf',
    [Parameter(Mandatory)][string[]]$SponsorUserIds,
    [string[]]$SponsorGroupIds = @(),
    [string[]]$OwnerUserIds = @(),
    [Parameter(Mandatory)][string]$ManagedIdentityPrincipalId,
    [string[]]$Agents = @('sim-analyst', 'drift-agent'),
    [switch]$GrantPurviewRead,
    [string]$GrantFile = './ppdf-agent-grant.json'
)

$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com'
$odata = @{ 'OData-Version' = '4.0' }

function Invoke-Graph([string]$Method, [string]$Uri, $Body = $null) {
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'HashTable'; Headers = $odata }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}
function Get-First([string]$Uri) { @((Invoke-Graph GET $Uri).value)[0] }

$sponsorBinds = @($SponsorUserIds | ForEach-Object { "$graph/v1.0/users/$_" }) + @($SponsorGroupIds | ForEach-Object { "$graph/v1.0/groups/$_" })
$ownerBinds = @($OwnerUserIds | ForEach-Object { "$graph/v1.0/users/$_" })

if (-not (Get-MgContext)) {
    $scopes = @('AgentIdentityBlueprint.Create', 'AgentIdentityBlueprintPrincipal.Create', 'AgentIdentityBlueprint.AddRemoveCreds.All',
        'AgentIdentityBlueprint.ReadWrite.All', 'AgentIdentity.Create.All', 'Application.Read.All')
    if ($GrantPurviewRead) { $scopes += 'AppRoleAssignment.ReadWrite.All' }
    Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
}

# 1. Blueprint
$bpName = "$Prefix-agents"
$bp = Get-First "v1.0/applications/microsoft.graph.agentIdentityBlueprint?`$filter=displayName eq '$bpName'"
if (-not $bp -and $PSCmdlet.ShouldProcess($bpName, 'Create agent identity blueprint')) {
    $body = @{ displayName = $bpName; 'sponsors@odata.bind' = $sponsorBinds }
    if ($ownerBinds) { $body['owners@odata.bind'] = $ownerBinds }
    $bp = Invoke-Graph POST 'v1.0/applications/microsoft.graph.agentIdentityBlueprint' -Body $body
}
if (-not $bp) { return } # -WhatIf

# 2. Blueprint principal
$bpSp = Get-First "v1.0/servicePrincipals?`$filter=appId eq '$($bp.appId)'"
if (-not $bpSp -and $PSCmdlet.ShouldProcess($bpName, 'Create blueprint principal')) {
    $bpSp = Invoke-Graph POST 'v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal' -Body @{ appId = $bp.appId }
}

# 3. Managed identity trust (no secrets). The agent host acquires an MI token, exchanges it for a blueprint token with
#    fmi_path=<agent identity client id>, then exchanges that for the agent identity's resource token.
$issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
$fics = @((Invoke-Graph GET "v1.0/applications/$($bp.id)/federatedIdentityCredentials").value)
if (-not ($fics | Where-Object { $_.issuer -eq $issuer -and $_.subject -eq $ManagedIdentityPrincipalId }) -and
    $PSCmdlet.ShouldProcess($bpName, "Trust managed identity $ManagedIdentityPrincipalId")) {
    Invoke-Graph POST "v1.0/applications/$($bp.id)/federatedIdentityCredentials" -Body @{
        name = 'agent-host-uami'; issuer = $issuer; subject = $ManagedIdentityPrincipalId; audiences = @('api://AzureADTokenExchange')
    } | Out-Null
}

# 4. Agent identities
$created = [ordered]@{}
foreach ($a in $Agents) {
    $name = "$Prefix-$a"
    $agent = Get-First "beta/servicePrincipals/microsoft.graph.agentIdentity?`$filter=displayName eq '$name'"
    if (-not $agent -and $PSCmdlet.ShouldProcess($name, 'Create agent identity')) {
        $agent = Invoke-Graph POST 'beta/servicePrincipals/microsoft.graph.agentIdentity' -Body @{
            displayName = $name; agentIdentityBlueprintId = $bp.appId; 'sponsors@odata.bind' = $sponsorBinds
        }
    }
    if ($agent) { $created[$a] = $agent }
}

# 5. Optional direct read access to Purview
if ($GrantPurviewRead -and $created.Count) {
    $exo = Get-First "v1.0/servicePrincipals?`$filter=appId eq '00000002-0000-0ff1-ce00-000000000000'"
    $mg = Get-First "v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'"
    $roles = @(
        @{ resourceId = $exo.id; appRoleId = ($exo.appRoles | Where-Object value -EQ 'Exchange.ManageAsApp').id }
        @{ resourceId = $mg.id; appRoleId = ($mg.appRoles | Where-Object value -EQ 'RoleEligibilitySchedule.Read.Directory').id }
        @{ resourceId = $mg.id; appRoleId = ($mg.appRoles | Where-Object value -EQ 'RoleAssignmentSchedule.Read.Directory').id }
    )
    $grant = [ordered]@{}
    foreach ($a in $created.Keys) {
        $agent = $created[$a]
        $have = @((Invoke-Graph GET "v1.0/servicePrincipals/$($agent.id)/appRoleAssignments").value)
        foreach ($r in $roles) {
            if ($have | Where-Object { $_.resourceId -eq $r.resourceId -and $_.appRoleId -eq $r.appRoleId }) { continue }
            if ($PSCmdlet.ShouldProcess($agent.displayName, "Grant app role $($r.appRoleId)")) {
                Invoke-Graph POST "v1.0/servicePrincipals/$($agent.id)/appRoleAssignments" -Body @{ principalId = $agent.id; resourceId = $r.resourceId; appRoleId = $r.appRoleId } | Out-Null
            }
        }
        $grant["agent-$a"] = [ordered]@{
            appId = $agent.appId; objectId = $agent.id; displayName = $agent.displayName; template = 'reader'
            roleGroup = ('{0}_AGENTS_READ' -f ($Prefix -replace '-', '_').ToUpperInvariant())
        }
    }
    $grant | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $GrantFile -Encoding utf8
    Write-Host "Grant file written to $GrantFile (verify that Security & Compliance PowerShell accepts agent identity tokens in your tenant)."
}

$created.Values | ForEach-Object { [pscustomobject]@{ Agent = $_.displayName; ClientId = $_.appId; ObjectId = $_.id; Blueprint = $bp.appId } } | Format-Table -AutoSize

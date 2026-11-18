# RBAC provider.
#   RoleGroup            -> Purview (Security & Compliance) role groups. Full management (RoleGroup, tagged in Description)
#                           or membership-only for built-in groups (RoleGroupMembership, untaggable).
#   EntraRoleAssignment  -> Entra ID role assignments through PIM schedule requests (eligible or active, time-bound).
# Neither has a simulation equivalent (strategy "whatif"): the plan is the preview and every change needs at least
# elevated approval.

# Defaults; extend per environment with spec.guardrails.sensitiveRoleGroupRoles.
$script:RbacSensitiveRoles = @(
    'Role Management', 'Organization Configuration', 'Search And Purge', 'Export', 'Compliance Search', 'Case Management',
    'Hold', 'Review', 'Data Classification Content Viewer', 'Insider Risk Management Investigation', 'Insider Risk Management Sessions'
)
# Global Administrator, Privileged Role Administrator, Privileged Authentication Administrator (template ids).
$script:RbacPrivilegedEntraRoles = @('62e90394-69f5-4237-9190-012177145e10', 'e8611ab8-c189-46e8-94e1-60213ab1f814', '7be44c8a-adaf-4e2a-84d6-ab2649e08a13')
$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

function Get-PpdfLeafName {
    param($Value)
    return @(foreach ($v in @(Get-PpdfLocationName $Value)) { ([string]$v -split '[\\/]')[-1] })
}

function Resolve-PpdfRoleGroupMember {
    <#
    .SYNOPSIS
    Normalizes Get-RoleGroupMember output so it compares against the identifiers used in the spec (UPN, mail, object id,
    app id or name). With MembersMode 'additive' only declared members are reported, so undeclared members are left alone.
    #>
    param($RawMembers, [string[]]$DesiredMembers = @(), [string]$Mode = 'authoritative')
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($m in @($RawMembers)) {
        if ($null -eq $m) { continue }
        $ids = @(foreach ($p in 'WindowsLiveID', 'PrimarySmtpAddress', 'ExternalDirectoryObjectId', 'AppId', 'ObjectId', 'Name', 'DisplayName', 'Identity') {
                $v = [string](Get-PpdfValue $m $p)
                if ($v) { $v }
            })
        if ($m -is [string]) { $ids = @($m) }
        $match = @($DesiredMembers | Where-Object { $d = $_; $ids | Where-Object { [string]::Equals($_, $d, [StringComparison]::OrdinalIgnoreCase) } })
        if ($match.Count) { $out.Add($match[0]); continue }
        if ($Mode -eq 'additive') { continue }
        $out.Add($ids[0])
    }
    return , $out.ToArray()
}

function Get-PpdfRoleGroupState {
    param([string]$Name, $Desired, [switch]$IncludeMembers)
    $g = Get-PpdfCmdletObject -Name 'Get-RoleGroup' -Parameters @{ Identity = $Name }
    if (-not $g) { return $null }
    $o = [ordered]@{
        Name            = [string](Get-PpdfValue $g 'Name')
        DisplayName     = [string](Get-PpdfValue $g 'DisplayName')
        Description     = [string](Get-PpdfValue $g 'Description')
        Roles           = @(Get-PpdfLeafName (Get-PpdfValue $g 'Roles' @()))
        ServiceIdentity = [string](Get-PpdfValue $g 'Identity' $Name)
    }
    if ($IncludeMembers) {
        $raw = @(Invoke-PpdfCmdlet -Name 'Get-RoleGroupMember' -Parameters @{ Identity = $o.ServiceIdentity; ResultSize = 'Unlimited' })
        $declared = @(Get-PpdfValue $Desired.Properties 'Members' @())
        $o.Members = @(Resolve-PpdfRoleGroupMember -RawMembers $raw -DesiredMembers $declared -Mode ([string](Get-PpdfValue $Desired.Options 'MembersMode' 'authoritative')))
    }
    return $o
}

function Update-PpdfRoleGroupMember {
    param($Desired, $Current)
    $identity = [string](Get-PpdfValue $Current 'ServiceIdentity' $Desired.Name)
    $delta = Get-PpdfListDelta -Desired (Get-PpdfValue $Desired.Properties 'Members' @()) -Current (Get-PpdfValue $Current 'Members' @())
    foreach ($m in $delta.Add) { Invoke-PpdfCmdlet -Name 'Add-RoleGroupMember' -Parameters @{ Identity = $identity; Member = [string]$m } }
    if ([string](Get-PpdfValue $Desired.Options 'MembersMode' 'authoritative') -eq 'additive') { return }
    foreach ($m in $delta.Remove) { Invoke-PpdfCmdlet -Name 'Remove-RoleGroupMember' -Parameters @{ Identity = $identity; Member = [string]$m; Confirm = $false } }
}

function Get-PpdfSensitiveRoleList {
    param($EnvSpec)
    $extra = @(Get-PpdfValue (Get-PpdfValue $EnvSpec 'guardrails' @{}) 'sensitiveRoleGroupRoles' @())
    return @($script:RbacSensitiveRoles + $extra | Where-Object { $_ } | Select-Object -Unique)
}

Register-PpdfObjectType -Name 'RoleGroup' -Workload 'rbac' -TagProperty 'Description' -Service 'scc' `
    -KnownProperties @('Description', 'Roles', 'Members') `
    -Get {
    param($Desired, $Context)
    return (Get-PpdfRoleGroupState -Name $Desired.Name -Desired $Desired -IncludeMembers)
} -ListManaged {
    param($Context)
    return (Get-PpdfTaggedList -Cmdlet 'Get-RoleGroup' -TagProperty 'Description' -Normalize {
            param($o) [ordered]@{ Name = [string](Get-PpdfValue $o 'Name'); Description = [string](Get-PpdfValue $o 'Description') }
        })
} -Create {
    param($Desired, $Context)
    Invoke-PpdfCmdlet -Name 'New-RoleGroup' -Parameters (New-PpdfCreateParameter -Desired $Desired)
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    $scalar = @($DiffKeys | Where-Object { $_ -in 'Description', 'DisplayName' })
    if ($scalar.Count) {
        $p = New-PpdfSetParameter -Desired $Desired -Current $Current -DiffKeys $scalar
        $p.Identity = [string](Get-PpdfValue $Current 'ServiceIdentity' $Desired.Name)
        Invoke-PpdfCmdlet -Name 'Set-RoleGroup' -Parameters $p
    }
    if ('Members' -in $DiffKeys) { Update-PpdfRoleGroupMember -Desired $Desired -Current $Current }
    if ('Roles' -in $DiffKeys) { throw "Roles of existing role group '$($Desired.Name)' cannot be changed in place; create a new role group." }
} -Remove {
    param($Desired, $Current, $Context)
    Invoke-PpdfCmdlet -Name 'Remove-RoleGroup' -Parameters @{ Identity = [string](Get-PpdfValue $Current 'ServiceIdentity' $Desired.Name); Confirm = $false }
}

Register-PpdfObjectType -Name 'RoleGroupMembership' -Workload 'rbac' -Service 'scc' `
    -KnownProperties @('Roles') `
    -Get {
    param($Desired, $Context)
    return (Get-PpdfRoleGroupState -Name $Desired.Name -Desired $Desired -IncludeMembers)
} -Create {
    param($Desired, $Context)
    throw "Role group '$($Desired.Name)' does not exist. membershipOnly manages members of an existing (built-in) role group."
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    if ('Members' -in $DiffKeys) { Update-PpdfRoleGroupMember -Desired $Desired -Current $Current }
} -Remove {
    param($Desired, $Current, $Context)
    # ensure: absent on a membership-only artifact removes the declared members, never the role group itself.
    $identity = [string](Get-PpdfValue $Current 'ServiceIdentity' $Desired.Name)
    foreach ($m in @(Get-PpdfValue $Desired.Properties 'Members' @())) {
        if ($m -in @(Get-PpdfValue $Current 'Members' @())) { Invoke-PpdfCmdlet -Name 'Remove-RoleGroupMember' -Parameters @{ Identity = $identity; Member = [string]$m; Confirm = $false } }
    }
}

Register-PpdfKind -Name 'RoleGroup' -Workload 'rbac' -IdentityRole 'rbac' -SimulationStrategy 'whatif' `
    -Description 'Purview role groups: full lifecycle for custom groups, or membership-only for built-in groups.' `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $members = @(Get-PpdfValue $spec 'members' @() | ForEach-Object { [string]$_ })
    $opts = [ordered]@{ MembersMode = [string](Get-PpdfValue $spec 'membersMode' 'authoritative') }
    if ((Get-PpdfValue $spec 'membershipOnly' $false) -eq $true) {
        New-PpdfDesiredObject -Type 'RoleGroupMembership' -Name $Artifact.Name -Order 10 -Primary -Properties ([ordered]@{ Members = $members }) -Options $opts
        return
    }
    $props = [ordered]@{ Description = [string](Get-PpdfValue $spec 'description' '') }
    $dn = Get-PpdfValue $spec 'displayName'
    if ($dn) { $props.DisplayName = [string]$dn }
    $props.Roles = @(Get-PpdfValue $spec 'roles' @() | ForEach-Object { [string]$_ })
    $props.Members = $members
    New-PpdfDesiredObject -Type 'RoleGroup' -Name $Artifact.Name -Order 10 -Primary -Properties $props -Options $opts
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    if ($Artifact.Name.Length -gt 64) { 'Role group name must be 64 characters or fewer.' }
    $membershipOnly = (Get-PpdfValue $spec 'membershipOnly' $false) -eq $true
    $roles = @(Get-PpdfValue $spec 'roles' @())
    if ($membershipOnly -and $roles.Count) { 'roles cannot be set when membershipOnly is true.' }
    if (-not $membershipOnly -and -not $roles.Count) { 'roles is required for a managed role group.' }
    $dup = @(Get-PpdfValue $spec 'members' @() | Group-Object { ([string]$_).ToLowerInvariant() } | Where-Object Count -gt 1)
    foreach ($d in $dup) { "Duplicate member '$($d.Name)'." }
} -Assess {
    param($Action, $Artifact, $Context)
    @{ Tier = 'elevated'; Reason = 'Changes who can administer Purview.' }
    $sensitive = Get-PpdfSensitiveRoleList $Context.Env
    $roles = @(@(Get-PpdfValue $Action.desired 'Roles' @()) + @(if ($Action.expected) { Get-PpdfValue $Action.expected 'Roles' @() }) | Where-Object { $_ })
    $hit = @($roles | Where-Object { $r = $_; $sensitive | Where-Object { [string]::Equals($_, $r, [StringComparison]::OrdinalIgnoreCase) } } | Select-Object -Unique)
    $grants = $Action.op -eq 'create' -or ($Action.op -in 'update', 'adopt' -and @($Action.diffKeys | Where-Object { $_ -in 'Roles', 'Members' }).Count)
    if ($hit.Count -and $grants) { @{ Tier = 'critical'; Reason = "Grants sensitive role(s): $($hit -join ', ')." } }
    if ($Action.type -eq 'RoleGroup' -and $Action.op -in 'update', 'adopt' -and 'Roles' -in $Action.diffKeys) {
        @{ Tier = 'elevated'; Reason = 'Roles of an existing role group cannot be changed in place; create a new role group and migrate members.'; Block = $true }
    }
} -Export {
    param($Context)
    foreach ($g in @(Invoke-PpdfCmdlet -Name 'Get-RoleGroup')) {
        if ($null -eq $g) { continue }
        $name = [string](Get-PpdfValue $g 'Name')
        $split = Split-PpdfTaggedText ([string](Get-PpdfValue $g 'Description'))
        $raw = @(Invoke-PpdfCmdlet -Name 'Get-RoleGroupMember' -Parameters @{ Identity = [string](Get-PpdfValue $g 'Identity' $name); ResultSize = 'Unlimited' })
        $members = @(Resolve-PpdfRoleGroupMember -RawMembers $raw)
        $spec = if ($split.Tag) {
            [ordered]@{ description = $split.Text; roles = @(Get-PpdfLeafName (Get-PpdfValue $g 'Roles' @())); members = $members }
        }
        else { [ordered]@{ membershipOnly = $true; members = $members } }
        $dn = [string](Get-PpdfValue $g 'DisplayName')
        if ($split.Tag -and $dn -and $dn -ne $name) { $spec.displayName = $dn }
        @{ Name = $name; Doc = (New-PpdfExportDocument -Kind 'RoleGroup' -Name $name -Spec $spec) }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Entra ID role assignments via PIM. Assignments carry no free-text field for an ownership tag, so they are identified
# by principal|role|scope|type and removed only through metadata.ensure: absent (no orphan detection).

function Get-PpdfEntraScheduleSegment {
    param([string]$AssignmentType)
    if ($AssignmentType -eq 'active') { return 'roleAssignmentSchedule' }
    return 'roleEligibilitySchedule'
}

function Get-PpdfEntraAssignmentSchedule {
    param([string]$PrincipalId, [string]$RoleDefinitionId, [string]$DirectoryScopeId, [string]$AssignmentType)
    $seg = Get-PpdfEntraScheduleSegment $AssignmentType
    $filter = [uri]::EscapeDataString("principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'")
    $items = @(Get-PpdfGraphCollection -Uri "v1.0/roleManagement/directory/${seg}s?`$filter=$filter")
    return @($items | Where-Object {
            [string](Get-PpdfValue $_ 'directoryScopeId' '/') -eq $DirectoryScopeId -and
            ($AssignmentType -ne 'active' -or [string](Get-PpdfValue $_ 'assignmentType' 'Assigned') -eq 'Assigned')
        })
}

function New-PpdfEntraScheduleRequest {
    param($Desired, [ValidateSet('adminAssign', 'adminUpdate', 'adminRemove')][string]$Action)
    $p = $Desired.Properties
    $body = [ordered]@{
        action           = $Action
        principalId      = [string]$p.PrincipalId
        roleDefinitionId = [string]$p.RoleDefinitionId
        directoryScopeId = [string]$p.DirectoryScopeId
        justification    = [string](Get-PpdfValue $Desired.Options 'Justification' 'Managed by PPDF')
    }
    if ($Action -ne 'adminRemove') {
        $duration = [string](Get-PpdfValue $Desired.Options 'Duration' 'P365D')
        $expiration = if ($duration -eq 'permanent') { [ordered]@{ type = 'noExpiration' } } else { [ordered]@{ type = 'afterDuration'; duration = $duration } }
        $body.scheduleInfo = [ordered]@{ startDateTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); expiration = $expiration }
    }
    $ticket = Get-PpdfValue $Desired.Options 'Ticket'
    if ($ticket) { $body.ticketInfo = [ordered]@{ ticketNumber = [string]$ticket; ticketSystem = [string](Get-PpdfValue $Desired.Options 'TicketSystem' 'ppdf') } }
    $seg = Get-PpdfEntraScheduleSegment ([string]$p.AssignmentType)
    return (Invoke-PpdfGraph -Method POST -Uri "v1.0/roleManagement/directory/${seg}Requests" -Body $body)
}

Register-PpdfObjectType -Name 'EntraRoleAssignment' -Workload 'rbac' -Service 'graph' `
    -KnownProperties @('PrincipalId', 'RoleDefinitionId', 'DirectoryScopeId', 'AssignmentType') `
    -Get {
    param($Desired, $Context)
    $p = $Desired.Properties
    $s = @(Get-PpdfEntraAssignmentSchedule -PrincipalId $p.PrincipalId -RoleDefinitionId $p.RoleDefinitionId -DirectoryScopeId $p.DirectoryScopeId -AssignmentType $p.AssignmentType)
    if (-not $s.Count) { return $null }
    return [ordered]@{
        PrincipalId      = [string](Get-PpdfValue $s[0] 'principalId')
        RoleDefinitionId = [string](Get-PpdfValue $s[0] 'roleDefinitionId')
        DirectoryScopeId = [string](Get-PpdfValue $s[0] 'directoryScopeId' '/')
        AssignmentType   = [string]$p.AssignmentType
        EndDateTime      = [string](Get-PpdfPathValue $s[0] @('scheduleInfo.expiration.endDateTime'))
    }
} -Create {
    param($Desired, $Context)
    New-PpdfEntraScheduleRequest -Desired $Desired -Action 'adminAssign' | Out-Null
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    New-PpdfEntraScheduleRequest -Desired $Desired -Action 'adminUpdate' | Out-Null
} -Remove {
    param($Desired, $Current, $Context)
    New-PpdfEntraScheduleRequest -Desired $Desired -Action 'adminRemove' | Out-Null
}

Register-PpdfKind -Name 'EntraRoleAssignment' -Workload 'rbac' -IdentityRole 'rbac' -SimulationStrategy 'whatif' `
    -Description 'Entra ID directory role assignments (PIM eligible or time-bound active), restricted by environment guardrails.' `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $type = [string](Get-PpdfValue $spec 'assignmentType' 'eligible')
    $scope = [string](Get-PpdfValue $spec 'directoryScopeId' '/')
    $props = [ordered]@{ PrincipalId = ([string]$spec.principalId).ToLowerInvariant(); RoleDefinitionId = ([string]$spec.roleDefinitionId).ToLowerInvariant(); DirectoryScopeId = $scope; AssignmentType = $type }
    $opts = [ordered]@{ Duration = [string](Get-PpdfValue $spec 'duration' 'P365D'); Justification = [string](Get-PpdfValue $spec 'justification' "PPDF artifact $($Artifact.Id)") }
    $ticket = Get-PpdfValue $spec 'ticket'
    if ($ticket) { $opts.Ticket = [string]$ticket }
    New-PpdfDesiredObject -Type 'EntraRoleAssignment' -Name ('{0}|{1}|{2}|{3}' -f $props.PrincipalId, $props.RoleDefinitionId, $scope, $type) -Order 10 -Primary -Properties $props -Options $opts
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    $pid_ = [string]$spec.principalId
    $rid = [string]$spec.roleDefinitionId
    if ($pid_ -notmatch $script:GuidPattern) { 'principalId must be an object id (GUID).' }
    if ($rid -notmatch $script:GuidPattern) { 'roleDefinitionId must be a role template id (GUID).' }
    $g = Get-PpdfValue $EnvSpec 'guardrails' @{}
    $roles = @(Get-PpdfValue $g 'entraRoleAllowlist' @())
    if (-not $roles.Count) { 'Environment spec.guardrails.entraRoleAllowlist must list the Entra roles this pipeline may assign.' }
    elseif (-not ($roles | Where-Object { [string]::Equals([string]$_, $rid, [StringComparison]::OrdinalIgnoreCase) })) { "Role $rid is not in this environment's guardrails.entraRoleAllowlist." }
    $principals = @(Get-PpdfValue $g 'entraPrincipalAllowlist' @())
    if ($principals.Count -and -not ($principals | Where-Object { [string]::Equals([string]$_, $pid_, [StringComparison]::OrdinalIgnoreCase) })) { "Principal $pid_ is not in this environment's guardrails.entraPrincipalAllowlist." }
    $duration = [string](Get-PpdfValue $spec 'duration' 'P365D')
    if ($duration -ne 'permanent') { try { [void][System.Xml.XmlConvert]::ToTimeSpan($duration) } catch { "duration '$duration' is not an ISO 8601 duration (or 'permanent')." } }
} -Assess {
    param($Action, $Artifact, $Context)
    @{ Tier = 'elevated'; Reason = 'Changes Entra ID directory role assignments.' }
    if ([string]$Action.desired.RoleDefinitionId -in $script:RbacPrivilegedEntraRoles) { @{ Tier = 'critical'; Reason = 'Privileged Entra role (tenant takeover risk).' } }
    if ($Action.op -ne 'delete' -and [string]$Action.desired.AssignmentType -eq 'active' -and [string](Get-PpdfValue $Action.options 'Duration') -eq 'permanent') {
        @{ Tier = 'critical'; Reason = 'Permanent active (standing) assignment; prefer eligible or time-bound.' }
    }
} -Export {
    param($Context)
    $roles = @(Get-PpdfValue (Get-PpdfValue $Context.Env 'guardrails' @{}) 'entraRoleAllowlist' @())
    foreach ($rid in $roles) {
        foreach ($type in 'eligible', 'active') {
            $seg = Get-PpdfEntraScheduleSegment $type
            $filter = [uri]::EscapeDataString("roleDefinitionId eq '$rid'")
            foreach ($s in @(Get-PpdfGraphCollection -Uri "v1.0/roleManagement/directory/${seg}s?`$filter=$filter")) {
                if ($type -eq 'active' -and [string](Get-PpdfValue $s 'assignmentType' 'Assigned') -ne 'Assigned') { continue }
                $principal = [string](Get-PpdfValue $s 'principalId')
                $end = Get-PpdfPathValue $s @('scheduleInfo.expiration.endDateTime')
                $spec = [ordered]@{ principalId = $principal; roleDefinitionId = $rid; directoryScopeId = [string](Get-PpdfValue $s 'directoryScopeId' '/'); assignmentType = $type; duration = if ($end) { 'P365D' } else { 'permanent' } }
                $name = "$type-$($rid.Substring(0, 8))-$($principal.Substring(0, [Math]::Min(8, $principal.Length)))"
                @{ Name = $name; Doc = (New-PpdfExportDocument -Kind 'EntraRoleAssignment' -Name $name -Spec $spec -Description 'Exported PIM schedule; review duration before applying.') }
            }
        }
    }
}

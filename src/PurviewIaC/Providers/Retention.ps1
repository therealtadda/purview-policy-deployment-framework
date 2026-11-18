# Retention provider:
#   RetentionPolicy      -> RetentionCompliancePolicy + one RetentionComplianceRule ("<policy>-Rule")
#   RetentionLabel       -> ComplianceTag
#   RetentionLabelPolicy -> RetentionCompliancePolicy + RetentionComplianceRule per published/auto-applied label
# Retention has no native "test mode". The simulate stage deploys a non-destructive equivalent (Keep only, no
# Preservation Lock) and measures distribution; deletion and locks are only ever applied at the enforce stage.

$script:RetentionNoise = @('Identity', 'Guid', 'Id', 'WhenCreated', 'WhenChanged', 'WhenCreatedUTC', 'WhenChangedUTC', 'CreatedBy', 'LastModifiedBy', 'ModificationTimeUtc', 'CreationTimeUtc', 'ObjectVersion', 'ImmutableId', 'DistributionResults', 'DistributionSyncStatus', 'ReadOnly', 'ExternalIdentity', 'PolicyCategory', 'DistributionStatus', 'Workload')
$script:RetentionTeamsLocations = @('TeamsChannelLocation', 'TeamsChatLocation', 'TeamsChannelLocationException', 'TeamsChatLocationException')
$script:RetentionDeletingActions = @('Delete', 'KeepAndDelete')

function ConvertTo-PpdfRetentionPolicyState {
    param($InputObject)
    $o = ConvertTo-PpdfObjectDictionary -InputObject $InputObject -Exclude $script:RetentionNoise
    foreach ($k in @($o.Keys)) { if (Test-PpdfLocationKey $k) { $o[$k] = Get-PpdfLocationName (Get-PpdfValue $InputObject $k) } }
    $o['Name'] = [string](Get-PpdfValue $InputObject 'Name')
    return $o
}

function ConvertTo-PpdfRetentionRuleState {
    param($InputObject, [hashtable]$PolicyNames = @{})
    $o = ConvertTo-PpdfObjectDictionary -InputObject $InputObject -Exclude $script:RetentionNoise
    $o['Name'] = [string](Get-PpdfValue $InputObject 'Name')
    $policy = [string](Get-PpdfValue $InputObject 'Policy')
    $o['Parent'] = if ($PolicyNames.ContainsKey($policy)) { $PolicyNames[$policy] } else { $policy }
    if (Test-PpdfHasKey $o 'RetentionDuration') { $o['RetentionDuration'] = [string]$o['RetentionDuration'] }
    return $o
}

function Get-PpdfRetentionPolicyNameMap {
    $map = @{}
    foreach ($p in @(Invoke-PpdfCmdlet -Name 'Get-RetentionCompliancePolicy')) {
        if ($null -eq $p) { continue }
        $n = [string]$p.Name
        foreach ($k in 'Guid', 'Identity', 'Id', 'ImmutableId', 'Name') { $v = [string](Get-PpdfValue $p $k); if ($v) { $map[$v] = $n } }
    }
    return $map
}

function ConvertTo-PpdfRetentionDay {
    <#
    .SYNOPSIS
    Converts a retention duration (days, or 'Unlimited') to a comparable number of days.
    #>
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ("$Value" -eq 'Unlimited') { return [double]::PositiveInfinity }
    $d = 0.0
    if ([double]::TryParse("$Value", [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Add-PpdfRetentionLocation {
    param([System.Collections.IDictionary]$Properties, $Spec)
    $locations = Get-PpdfValue $Spec 'locations' @{}
    foreach ($k in $locations.Keys) { $Properties[$k] = @($locations[$k]) }
    $extra = Get-PpdfValue $Spec 'parameters' @{}
    foreach ($k in $extra.Keys) { $Properties[$k] = $extra[$k] }
}

function Test-PpdfRetentionLocation {
    param($Spec)
    $locs = Get-PpdfValue $Spec 'locations' @{}
    $keys = @($locs.Keys | ForEach-Object { [string]$_ })
    if (@($keys | Where-Object { $_ -notmatch 'Exception$' }).Count -eq 0) { 'At least one location is required.' }
    $teams = @($keys | Where-Object { $_ -in $script:RetentionTeamsLocations })
    if ($teams.Count -and $teams.Count -ne $keys.Count) { 'Teams locations cannot be combined with other locations in the same retention policy.' }
}

#region Object types
Register-PpdfObjectType -Name 'RetentionCompliancePolicy' -Workload 'retention' -TagProperty 'Comment' -Service 'scc' `
    -KnownProperties @('Comment', 'Enabled', 'RestrictiveRetention', 'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation', 'ModernGroupLocation', 'TeamsChannelLocation', 'TeamsChatLocation', 'PublicFolderLocation', 'SkypeLocation') `
    -Get {
    param($Desired, $Context)
    $r = Get-PpdfCmdletObject -Name 'Get-RetentionCompliancePolicy' -Parameters @{ Identity = $Desired.Name }
    if (-not $r) { return $null }
    return (ConvertTo-PpdfRetentionPolicyState $r)
} -ListManaged {
    param($Context)
    return (Get-PpdfTaggedList -Cmdlet 'Get-RetentionCompliancePolicy' -TagProperty 'Comment' -Normalize { param($o) ConvertTo-PpdfRetentionPolicyState $o })
} -Create {
    param($Desired, $Context)
    Invoke-PpdfCmdlet -Name 'New-RetentionCompliancePolicy' -Parameters (New-PpdfCreateParameter -Desired $Desired)
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    $p = New-PpdfSetParameter -Desired $Desired -Current $Current -DiffKeys $DiffKeys
    if ($p.Contains('RestrictiveRetention') -and $p.RestrictiveRetention) { $p.Confirm = $false }
    Invoke-PpdfCmdlet -Name 'Set-RetentionCompliancePolicy' -Parameters $p
} -Remove {
    param($Desired, $Current, $Context)
    Invoke-PpdfCmdlet -Name 'Remove-RetentionCompliancePolicy' -Parameters @{ Identity = $Desired.Name; Confirm = $false }
}

Register-PpdfObjectType -Name 'RetentionComplianceRule' -Workload 'retention' -TagProperty 'Comment' -Service 'scc' `
    -KnownProperties @('Comment', 'RetentionDuration', 'RetentionComplianceAction', 'ExpirationDateOption') `
    -Get {
    param($Desired, $Context)
    $r = Get-PpdfCmdletObject -Name 'Get-RetentionComplianceRule' -Parameters @{ Identity = $Desired.Name }
    if (-not $r) { return $null }
    $state = ConvertTo-PpdfRetentionRuleState $r
    if ($Desired.Parent) { $state['Parent'] = $Desired.Parent }
    return $state
} -ListManaged {
    param($Context)
    $policyNameMap = Get-PpdfRetentionPolicyNameMap
    # $policyNameMap is resolved through dynamic scoping when Get-PpdfTaggedList invokes the scriptblock.
    return (Get-PpdfTaggedList -Cmdlet 'Get-RetentionComplianceRule' -TagProperty 'Comment' -Normalize { param($o) ConvertTo-PpdfRetentionRuleState $o -PolicyNames $policyNameMap })
} -Create {
    param($Desired, $Context)
    Invoke-PpdfCmdlet -Name 'New-RetentionComplianceRule' -Parameters (New-PpdfCreateParameter -Desired $Desired -Extra @{ Policy = $Desired.Options.Policy })
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    $p = New-PpdfSetParameter -Desired $Desired -Current $Current -DiffKeys $DiffKeys -Exclude @('PublishComplianceTag', 'ApplyComplianceTag')
    Invoke-PpdfCmdlet -Name 'Set-RetentionComplianceRule' -Parameters $p
} -Remove {
    param($Desired, $Current, $Context)
    Invoke-PpdfCmdlet -Name 'Remove-RetentionComplianceRule' -Parameters @{ Identity = $Desired.Name; Confirm = $false }
}

Register-PpdfObjectType -Name 'ComplianceTag' -Workload 'retention' -TagProperty 'Comment' -Service 'scc' `
    -KnownProperties @('Comment', 'RetentionAction', 'RetentionDuration', 'RetentionType', 'IsRecordLabel', 'Regulatory', 'Notes') `
    -Get {
    param($Desired, $Context)
    $r = Get-PpdfCmdletObject -Name 'Get-ComplianceTag' -Parameters @{ Identity = $Desired.Name }
    if (-not $r) { return $null }
    $o = ConvertTo-PpdfRetentionPolicyState $r
    if (Test-PpdfHasKey $o 'RetentionDuration') { $o['RetentionDuration'] = [string]$o['RetentionDuration'] }
    return $o
} -ListManaged {
    param($Context)
    return (Get-PpdfTaggedList -Cmdlet 'Get-ComplianceTag' -TagProperty 'Comment' -Normalize { param($o) ConvertTo-PpdfRetentionPolicyState $o })
} -Create {
    param($Desired, $Context)
    Invoke-PpdfCmdlet -Name 'New-ComplianceTag' -Parameters (New-PpdfCreateParameter -Desired $Desired)
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    $p = New-PpdfSetParameter -Desired $Desired -Current $Current -DiffKeys $DiffKeys -Exclude @('RetentionAction', 'RetentionType', 'IsRecordLabel', 'Regulatory')
    Invoke-PpdfCmdlet -Name 'Set-ComplianceTag' -Parameters $p
} -Remove {
    param($Desired, $Current, $Context)
    Invoke-PpdfCmdlet -Name 'Remove-ComplianceTag' -Parameters @{ Identity = $Desired.Name; Confirm = $false }
}
#endregion

#region RetentionPolicy
Register-PpdfKind -Name 'RetentionPolicy' -Workload 'retention' -IdentityRole 'retention' -SimulationStrategy 'mode' -RequiresSimulationEvidence $true `
    -Description 'Retention policy (locations) with a single retention rule. Simulation deploys a Keep-only, unlocked equivalent.' `
    -DefaultThresholds @{ requireDistributionSuccess = $true } `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $simulate = ($Stage -eq 'simulate')
    $props = [ordered]@{ Comment = [string](Get-PpdfValue $spec 'comment' ''); Enabled = [bool](Get-PpdfValue $spec 'enabled' $true) }
    Add-PpdfRetentionLocation -Properties $props -Spec $spec
    $restrictive = [bool](Get-PpdfValue $spec 'restrictiveRetention' $false)
    if ($restrictive -and -not $simulate) { $props['RestrictiveRetention'] = $true }
    Set-PpdfLocationOverride -Properties $props -Override (Get-PpdfLocationOverride -Artifact $Artifact -Context $Context -Stage $Stage)
    New-PpdfDesiredObject -Type 'RetentionCompliancePolicy' -Name $Artifact.Name -Order 10 -Properties $props -Primary

    $rule = Get-PpdfValue $spec 'rule' @{}
    $action = [string](Get-PpdfValue $rule 'retentionComplianceAction' 'Keep')
    if ($simulate -and $action -in $script:RetentionDeletingActions) { $action = 'Keep' }
    $rp = [ordered]@{
        Comment                   = [string](Get-PpdfValue $rule 'comment' '')
        RetentionDuration         = [string](Get-PpdfValue $rule 'retentionDuration' 'Unlimited')
        RetentionComplianceAction = $action
    }
    $exp = Get-PpdfValue $rule 'expirationDateOption'
    if ($exp) { $rp['ExpirationDateOption'] = [string]$exp }
    $rparams = Get-PpdfValue $rule 'parameters' @{}
    foreach ($k in $rparams.Keys) { $rp[$k] = $rparams[$k] }
    New-PpdfDesiredObject -Type 'RetentionComplianceRule' -Name "$($Artifact.Name)-Rule" -Parent $Artifact.Name -Order 20 -Properties $rp -Options ([ordered]@{ Policy = $Artifact.Name })
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    if ($Artifact.Name.Length -gt 59) { 'Policy name must be at most 59 characters (the rule is named <policy>-Rule).' }
    Test-PpdfRetentionLocation $spec
    if ((Get-PpdfValue $spec 'restrictiveRetention' $false) -and -not (Get-PpdfValue $spec 'acknowledgeIrreversible' $false)) {
        'restrictiveRetention (Preservation Lock) is irreversible: set spec.acknowledgeIrreversible: true to confirm.'
    }
    $d = ConvertTo-PpdfRetentionDay (Get-PpdfValue (Get-PpdfValue $spec 'rule' @{}) 'retentionDuration' 'Unlimited')
    if ($null -eq $d) { 'rule.retentionDuration must be a number of days or Unlimited.' }
} -Assess {
    param($Action, $Artifact, $Context)
    $d = $Action.desired; $e = $Action.expected
    if ($Action.type -eq 'RetentionCompliancePolicy') {
        if ($d.RestrictiveRetention -eq $true -and ($Action.op -ne 'update' -or 'RestrictiveRetention' -in $Action.diffKeys)) {
            @{ Tier = 'critical'; Reason = 'Enables Preservation Lock (irreversible: the policy can no longer be disabled, deleted or reduced).' }
            if (-not (Get-PpdfValue $Artifact.Doc.spec 'acknowledgeIrreversible' $false)) { @{ Tier = 'critical'; Reason = 'Preservation Lock not acknowledged (spec.acknowledgeIrreversible).'; Block = $true } }
        }
        if ($Action.op -eq 'update' -and $e) {
            foreach ($k in @($Action.diffKeys | Where-Object { Test-PpdfLocationKey $_ -and $_ -notmatch 'Exception$' })) {
                $removed = @((Get-PpdfListDelta -Desired $d[$k] -Current $e[$k]).Remove)
                if ($removed.Count) { @{ Tier = 'elevated'; Reason = "Removes $k scope ($($removed -join ', ')): content stops being retained." } }
            }
            if ($e.RestrictiveRetention -eq $true -and 'Enabled' -in $Action.diffKeys -and $d.Enabled -eq $false) {
                @{ Tier = 'critical'; Reason = 'Cannot disable a policy with Preservation Lock.'; Block = $true }
            }
        }
    }
    if ($Action.type -eq 'RetentionComplianceRule' -and $Action.op -eq 'update' -and $e) {
        $newDays = ConvertTo-PpdfRetentionDay $d.RetentionDuration
        $oldDays = ConvertTo-PpdfRetentionDay $e.RetentionDuration
        if ($null -ne $newDays -and $null -ne $oldDays -and $newDays -lt $oldDays) { @{ Tier = 'critical'; Reason = "Shortens retention from $($e.RetentionDuration) to $($d.RetentionDuration) days." } }
        if ([string]$d.RetentionComplianceAction -in $script:RetentionDeletingActions -and [string]$e.RetentionComplianceAction -notin $script:RetentionDeletingActions) {
            @{ Tier = 'critical'; Reason = "Switches the retention action to $($d.RetentionComplianceAction): content will be deleted when the period ends." }
        }
    }
    if ($Action.type -eq 'RetentionComplianceRule' -and $Action.op -eq 'create' -and $Action.stage -eq 'enforce' -and [string]$d.RetentionComplianceAction -in $script:RetentionDeletingActions) {
        @{ Tier = 'critical'; Reason = 'Creates a deleting retention rule.' }
    }
} -SimulationResult {
    param($Artifact, $Context, $Target)
    $p = Get-PpdfCmdletObject -Name 'Get-RetentionCompliancePolicy' -Parameters @{ Identity = $Target.Target; DistributionDetail = $true }
    $results = @(if ($p) { Get-PpdfValue $p 'DistributionResults' @() })
    return [ordered]@{
        distributionSuccess = ([string](Get-PpdfValue $p 'DistributionStatus') -eq 'Success')
        distributionStatus  = [string](Get-PpdfValue $p 'DistributionStatus')
        distributionErrors  = @($results | Where-Object { $_ } | ForEach-Object { [string]$_ })
        distributionErrorCount = $results.Count
    }
} -Export {
    param($Context)
    $rules = @(Invoke-PpdfCmdlet -Name 'Get-RetentionComplianceRule')
    foreach ($p in @(Invoke-PpdfCmdlet -Name 'Get-RetentionCompliancePolicy')) {
        $guid = [string](Get-PpdfValue $p 'Guid')
        $name = [string]$p.Name
        $prules = @($rules | Where-Object { [string]$_.Policy -in $guid, $name })
        if ($prules.Count -ne 1) { continue }
        $r = $prules[0]
        if ((Get-PpdfValue $r 'PublishComplianceTag') -or (Get-PpdfValue $r 'ApplyComplianceTag')) { continue }
        $state = ConvertTo-PpdfRetentionPolicyState $p
        $spec = [ordered]@{ comment = (Split-PpdfTaggedText ([string]$state.Comment)).Text; enabled = [bool]$state.Enabled; locations = [ordered]@{} }
        foreach ($k in $state.Keys) { if ((Test-PpdfLocationKey $k) -and @($state[$k]).Count) { $spec.locations[$k] = @($state[$k]) } }
        if ($state.RestrictiveRetention) { $spec.restrictiveRetention = $true; $spec.acknowledgeIrreversible = $true }
        $spec.rule = [ordered]@{
            retentionDuration         = [string](Get-PpdfValue $r 'RetentionDuration' 'Unlimited')
            retentionComplianceAction = [string](Get-PpdfValue $r 'RetentionComplianceAction' 'Keep')
        }
        $exp = Get-PpdfValue $r 'ExpirationDateOption'
        if ($exp) { $spec.rule.expirationDateOption = [string]$exp }
        @{ Name = $name; Doc = (New-PpdfExportDocument -Kind 'RetentionPolicy' -Name $name -Spec $spec); Files = @{} }
    }
}
#endregion

#region RetentionLabel
$script:RetentionLabelImmutable = @('RetentionAction', 'RetentionType', 'IsRecordLabel', 'Regulatory')
$script:RetentionLabelMap = [ordered]@{
    retentionAction   = 'RetentionAction'
    retentionDuration = 'RetentionDuration'
    retentionType     = 'RetentionType'
    isRecordLabel     = 'IsRecordLabel'
    regulatory        = 'Regulatory'
    notes             = 'Notes'
    reviewerEmail     = 'ReviewerEmail'
}

Register-PpdfKind -Name 'RetentionLabel' -Workload 'retention' -IdentityRole 'retention' -SimulationStrategy 'none' `
    -Description 'Retention label (ComplianceTag). Inert until published or auto-applied by a RetentionLabelPolicy.' `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $props = [ordered]@{ Comment = [string](Get-PpdfValue $spec 'comment' '') }
    foreach ($k in $script:RetentionLabelMap.Keys) {
        $v = Get-PpdfValue $spec $k
        if ($null -ne $v) { $props[$script:RetentionLabelMap[$k]] = if ($k -eq 'retentionDuration') { [string]$v } else { $v } }
    }
    $extra = Get-PpdfValue $spec 'parameters' @{}
    foreach ($k in $extra.Keys) { $props[$k] = $extra[$k] }
    New-PpdfDesiredObject -Type 'ComplianceTag' -Name $Artifact.Name -Order 5 -Properties $props -Primary
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    if ((Get-PpdfValue $spec 'regulatory' $false) -and -not (Get-PpdfValue $spec 'isRecordLabel' $false)) { 'regulatory labels must also set isRecordLabel: true.' }
    $action = [string](Get-PpdfValue $spec 'retentionAction' '')
    if ($action -and $action -ne 'None' -and -not (Get-PpdfValue $spec 'retentionDuration')) { 'retentionDuration is required when retentionAction is set.' }
} -Assess {
    param($Action, $Artifact, $Context)
    if ($Action.op -eq 'update') {
        $immutable = @($Action.diffKeys | Where-Object { $_ -in $script:RetentionLabelImmutable })
        if ($immutable.Count) { @{ Tier = 'critical'; Reason = "Retention label properties cannot be changed in place: $($immutable -join ', '). Create a new label instead."; Block = $true } }
        $newDays = ConvertTo-PpdfRetentionDay $Action.desired.RetentionDuration
        $oldDays = if ($Action.expected) { ConvertTo-PpdfRetentionDay $Action.expected.RetentionDuration } else { $null }
        if ($null -ne $newDays -and $null -ne $oldDays -and $newDays -lt $oldDays) { @{ Tier = 'critical'; Reason = 'Shortens a retention label duration.' } }
    }
    if ($Action.op -in 'create', 'adopt', 'update' -and ($Action.desired.IsRecordLabel -eq $true -or $Action.desired.Regulatory -eq $true)) {
        @{ Tier = 'critical'; Reason = 'Record/regulatory label: items labelled with it cannot be edited or deleted and the label cannot be removed.' }
    }
} -Export {
    param($Context)
    foreach ($t in @(Invoke-PpdfCmdlet -Name 'Get-ComplianceTag')) {
        $state = ConvertTo-PpdfRetentionPolicyState $t
        $spec = [ordered]@{ comment = (Split-PpdfTaggedText ([string]$state.Comment)).Text }
        foreach ($k in $script:RetentionLabelMap.Keys) {
            $v = Get-PpdfValue $state $script:RetentionLabelMap[$k]
            if ($null -ne $v -and "$v" -ne '') { $spec[$k] = if ($k -eq 'retentionDuration') { [string]$v } else { $v } }
        }
        @{ Name = [string]$t.Name; Doc = (New-PpdfExportDocument -Kind 'RetentionLabel' -Name ([string]$t.Name) -Spec $spec); Files = @{} }
    }
}
#endregion

#region RetentionLabelPolicy
Register-PpdfKind -Name 'RetentionLabelPolicy' -Workload 'retention' -IdentityRole 'retention' -SimulationStrategy 'whatif' `
    -Description 'Publishes retention labels to locations, or auto-applies one label by query / sensitive information type.' `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $props = [ordered]@{ Comment = [string](Get-PpdfValue $spec 'comment' ''); Enabled = [bool](Get-PpdfValue $spec 'enabled' $true) }
    Add-PpdfRetentionLocation -Properties $props -Spec $spec
    Set-PpdfLocationOverride -Properties $props -Override (Get-PpdfLocationOverride -Artifact $Artifact -Context $Context -Stage $Stage)
    New-PpdfDesiredObject -Type 'RetentionCompliancePolicy' -Name $Artifact.Name -Order 10 -Properties $props -Primary
    $ignore = @('PublishComplianceTag', 'ApplyComplianceTag')
    $i = 0
    foreach ($label in @(Get-PpdfValue $spec 'publishLabels' @())) {
        $i++
        New-PpdfDesiredObject -Type 'RetentionComplianceRule' -Name "$($Artifact.Name)-$label" -Parent $Artifact.Name -Order (20 + $i) `
            -Properties ([ordered]@{ Comment = ''; PublishComplianceTag = [string]$label }) -Options ([ordered]@{ Policy = $Artifact.Name; IgnoreCompare = $ignore })
    }
    $auto = Get-PpdfValue $spec 'autoApply'
    if ($auto) {
        $rp = [ordered]@{ Comment = ''; ApplyComplianceTag = [string]$auto.label }
        $q = Get-PpdfValue $auto 'contentMatchQuery'
        if ($q) { $rp['ContentMatchQuery'] = [string]$q }
        $sits = @(Get-PpdfValue $auto 'sensitiveInformationTypes' @())
        if ($sits.Count) {
            $rp['ContentContainsSensitiveInformation'] = @(foreach ($s in $sits) {
                    $h = [ordered]@{ name = [string]$s.name }
                    foreach ($k in 'minCount', 'maxCount', 'minConfidence', 'maxConfidence') { $v = Get-PpdfValue $s $k; if ($null -ne $v) { $h[$k] = [string]$v } }
                    $h
                })
        }
        New-PpdfDesiredObject -Type 'RetentionComplianceRule' -Name "$($Artifact.Name)-$($auto.label)" -Parent $Artifact.Name -Order 30 `
            -Properties $rp -Options ([ordered]@{ Policy = $Artifact.Name; IgnoreCompare = $ignore })
    }
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    $publish = @(Get-PpdfValue $spec 'publishLabels' @())
    $auto = Get-PpdfValue $spec 'autoApply'
    if ($publish.Count -and $auto) { 'Use either publishLabels or autoApply, not both (separate policies).' }
    if (-not $publish.Count -and -not $auto) { 'One of publishLabels or autoApply is required.' }
    if ($auto -and -not (Get-PpdfValue $auto 'contentMatchQuery') -and -not @(Get-PpdfValue $auto 'sensitiveInformationTypes' @()).Count) { 'autoApply needs contentMatchQuery or sensitiveInformationTypes.' }
    Test-PpdfRetentionLocation $spec
    foreach ($l in $publish + @(if ($auto) { $auto.label })) { if ("$($Artifact.Name)-$l".Length -gt 64) { "Rule name '$($Artifact.Name)-$l' exceeds 64 characters." } }
} -Assess {
    param($Action, $Artifact, $Context)
    if ($Action.type -eq 'RetentionComplianceRule' -and (Test-PpdfHasKey $Action.desired 'ApplyComplianceTag') -and $Action.op -in 'create', 'update') {
        @{ Tier = 'elevated'; Reason = 'Auto-applies a retention label to existing content (not simulated in Phase 1).' }
    }
}
#endregion

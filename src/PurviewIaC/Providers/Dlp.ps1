# DLP provider: kind DlpPolicy -> object types DlpCompliancePolicy (+ DlpComplianceRule children).
# Simulation strategy "mode": the simulate stage deploys the policy in a test mode (in place, or as a "-ppdfsim"
# shadow copy when the live policy is already enforced) and measures matches from Activity Explorer.

$script:DlpShadowSuffix = '-ppdfsim'
$script:DlpPolicyNoise = @('Identity', 'Guid', 'Id', 'WhenCreated', 'WhenChanged', 'WhenCreatedUTC', 'WhenChangedUTC', 'CreatedBy', 'LastModifiedBy', 'ModificationTimeUtc', 'CreationTimeUtc', 'ObjectVersion', 'ImmutableId', 'DistributionResults', 'DistributionSyncStatus', 'Workload', 'ReadOnly', 'ExternalIdentity', 'PolicyCategory')

function ConvertTo-PpdfDlpPolicyState {
    param($InputObject)
    $o = ConvertTo-PpdfObjectDictionary -InputObject $InputObject -Exclude $script:DlpPolicyNoise
    foreach ($k in @($o.Keys)) { if (Test-PpdfLocationKey $k) { $o[$k] = Get-PpdfLocationName (Get-PpdfValue $InputObject $k) } }
    $o['Name'] = [string](Get-PpdfValue $InputObject 'Name')
    return $o
}

function ConvertTo-PpdfDlpRuleState {
    param($InputObject)
    $o = ConvertTo-PpdfObjectDictionary -InputObject $InputObject -Exclude $script:DlpPolicyNoise
    $o['Name'] = [string](Get-PpdfValue $InputObject 'Name')
    $o['Parent'] = [string](Get-PpdfValue $InputObject 'ParentPolicyName')
    return $o
}

function Get-PpdfDlpSimulationMode {
    param($Artifact, $Context)
    $m = Get-PpdfValue (Get-PpdfValue $Artifact.Doc 'simulation' @{}) 'mode'
    if (-not $m) { $m = Get-PpdfValue (Get-PpdfValue $Context.Env 'simulation' @{}) 'dlpMode' }
    if (-not $m) { $m = 'TestWithoutNotifications' }
    return [string]$m
}

Register-PpdfObjectType -Name 'DlpCompliancePolicy' -Workload 'dlp' -TagProperty 'Comment' -Service 'scc' `
    -KnownProperties @('Comment', 'Mode', 'Priority', 'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation', 'TeamsLocation', 'EndpointDlpLocation', 'OnPremisesScannerDlpLocation', 'ThirdPartyAppDlpLocation', 'PowerBIDlpLocation') `
    -IgnoreCompare @('Priority') `
    -Get {
    param($Desired, $Context)
    $r = Get-PpdfCmdletObject -Name 'Get-DlpCompliancePolicy' -Parameters @{ Identity = $Desired.Name }
    if (-not $r) { return $null }
    return (ConvertTo-PpdfDlpPolicyState $r)
} -ListManaged {
    param($Context)
    return (Get-PpdfTaggedList -Cmdlet 'Get-DlpCompliancePolicy' -TagProperty 'Comment' -Normalize { param($o) ConvertTo-PpdfDlpPolicyState $o })
} -Create {
    param($Desired, $Context)
    Invoke-PpdfCmdlet -Name 'New-DlpCompliancePolicy' -Parameters (New-PpdfCreateParameter -Desired $Desired)
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    Invoke-PpdfCmdlet -Name 'Set-DlpCompliancePolicy' -Parameters (New-PpdfSetParameter -Desired $Desired -Current $Current -DiffKeys $DiffKeys)
} -Remove {
    param($Desired, $Current, $Context)
    Invoke-PpdfCmdlet -Name 'Remove-DlpCompliancePolicy' -Parameters @{ Identity = $Desired.Name; Confirm = $false }
}

Register-PpdfObjectType -Name 'DlpComplianceRule' -Workload 'dlp' -TagProperty 'Comment' -Service 'scc' `
    -KnownProperties @('Comment', 'Disabled') `
    -IgnoreCompare @('Priority') `
    -Get {
    param($Desired, $Context)
    $r = Get-PpdfCmdletObject -Name 'Get-DlpComplianceRule' -Parameters @{ Identity = $Desired.Name }
    if (-not $r) { return $null }
    return (ConvertTo-PpdfDlpRuleState $r)
} -ListManaged {
    param($Context)
    return (Get-PpdfTaggedList -Cmdlet 'Get-DlpComplianceRule' -TagProperty 'Comment' -Normalize { param($o) ConvertTo-PpdfDlpRuleState $o })
} -Create {
    param($Desired, $Context)
    Invoke-PpdfCmdlet -Name 'New-DlpComplianceRule' -Parameters (New-PpdfCreateParameter -Desired $Desired -Extra @{ Policy = $Desired.Options.Policy })
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    Invoke-PpdfCmdlet -Name 'Set-DlpComplianceRule' -Parameters (New-PpdfSetParameter -Desired $Desired -Current $Current -DiffKeys $DiffKeys)
} -Remove {
    param($Desired, $Current, $Context)
    Invoke-PpdfCmdlet -Name 'Remove-DlpComplianceRule' -Parameters @{ Identity = $Desired.Name; Confirm = $false }
}

Register-PpdfKind -Name 'DlpPolicy' -Workload 'dlp' -IdentityRole 'dlp' -SimulationStrategy 'mode' -RequiresSimulationEvidence $true -SupportsShadow $true `
    -Description 'Data loss prevention policy and its rules (Security & Compliance PowerShell).' `
    -DefaultThresholds @{ requireDistributionSuccess = $true } `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $suffix = if ($Shadow) { $script:DlpShadowSuffix } else { '' }
    $policyName = "$($Artifact.Name)$suffix"
    $mode = if ($Stage -eq 'simulate') { Get-PpdfDlpSimulationMode $Artifact $Context } else { [string](Get-PpdfValue $spec 'mode' 'Enable') }
    $props = [ordered]@{ Comment = [string](Get-PpdfValue $spec 'comment' ''); Mode = $mode }
    $locations = Get-PpdfValue $spec 'locations' @{}
    foreach ($k in $locations.Keys) { $props[$k] = @($locations[$k]) }
    $extra = Get-PpdfValue $spec 'parameters' @{}
    foreach ($k in $extra.Keys) { $props[$k] = $extra[$k] }
    if ($null -ne (Get-PpdfValue $spec 'priority')) { $props['Priority'] = [int]$spec.priority }
    Set-PpdfLocationOverride -Properties $props -Override (Get-PpdfLocationOverride -Artifact $Artifact -Context $Context -Stage $Stage)

    New-PpdfDesiredObject -Type 'DlpCompliancePolicy' -Name $policyName -Order 10 -Properties $props -Primary
    $i = 0
    foreach ($r in @(Get-PpdfValue $spec 'rules' @())) {
        $i++
        $rp = [ordered]@{ Comment = [string](Get-PpdfValue $r 'comment' ''); Disabled = [bool](Get-PpdfValue $r 'disabled' $false) }
        $rparams = Get-PpdfValue $r 'parameters' @{}
        foreach ($k in $rparams.Keys) { $rp[$k] = $rparams[$k] }
        $opts = [ordered]@{ Policy = $policyName }
        $ign = @(Get-PpdfValue $r 'ignoreCompare' @())
        if ($ign.Count) { $opts.IgnoreCompare = $ign }
        New-PpdfDesiredObject -Type 'DlpComplianceRule' -Name "$($r.name)$suffix" -Parent $policyName -Order (20 + $i) -Properties $rp -Options $opts
    }
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    $max = 64 - $script:DlpShadowSuffix.Length
    if ($Artifact.Name.Length -gt $max) { "Policy name must be at most $max characters (room for the '$($script:DlpShadowSuffix)' shadow suffix)." }
    $locs = Get-PpdfValue $spec 'locations' @{}
    if (@($locs.Keys | Where-Object { $_ -notmatch 'Exception$' }).Count -eq 0) { 'At least one location is required.' }
    $names = @{}
    foreach ($r in @(Get-PpdfValue $spec 'rules' @())) {
        $n = [string]$r.name
        if ($n.Length -gt $max) { "Rule '$n' must be at most $max characters." }
        if ($names.ContainsKey($n)) { "Duplicate rule name '$n'." }
        $names[$n] = $true
    }
} -Assess {
    param($Action, $Artifact, $Context)
    if ($Action.type -eq 'DlpCompliancePolicy' -and $Action.stage -eq 'enforce' -and $Action.op -eq 'update') {
        $locChanges = @($Action.diffKeys | Where-Object { Test-PpdfLocationKey $_ })
        if ($locChanges.Count) { @{ Tier = 'elevated'; Reason = "Changes scope of an enforced policy ($($locChanges -join ', '))." } }
        if ('Mode' -in $Action.diffKeys -and [string]$Action.desired.Mode -eq 'Disable') { @{ Tier = 'elevated'; Reason = 'Disables an enforced DLP policy.' } }
    }
    if ($Action.type -eq 'DlpComplianceRule' -and $Action.op -eq 'update' -and 'Disabled' -in $Action.diffKeys -and $Action.desired.Disabled -eq $true -and $Action.stage -eq 'enforce') {
        @{ Tier = 'elevated'; Reason = 'Disables an enforced DLP rule.' }
    }
} -SimulationResult {
    param($Artifact, $Context, $Target)
    $records = @(Get-PpdfActivityRecord -PolicyName $Target.Target -Since $Target.Since -Activity 'DLPRuleMatch')
    $users = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $perDay = @{}; $perRule = [ordered]@{}; $perWorkload = [ordered]@{}
    foreach ($rec in $records) {
        $u = [string](Get-PpdfPathValue $rec @('User', 'UserId', 'UserPrincipalName', 'Actor'))
        if ($u) { [void]$users.Add($u) }
        $t = Get-PpdfPathValue $rec @('Happened', 'ActivityTime', 'CreationTime', 'TimeStamp')
        $day = if ($t) { try { ([datetime]$t).ToUniversalTime().ToString('yyyy-MM-dd') } catch { 'unknown' } } else { 'unknown' }
        $perDay[$day] = 1 + [int](Get-PpdfValue $perDay $day 0)
        $rule = [string](Get-PpdfPathValue $rec @('RuleName', 'PolicyMatchInfo.RuleName', 'Rule', 'PolicyMatchInfo.Rules.RuleName'))
        if (-not $rule) { $rule = 'unknown' }
        $rule = $rule -replace [regex]::Escape($script:DlpShadowSuffix) + '$', ''
        $perRule[$rule] = 1 + [int](Get-PpdfValue $perRule $rule 0)
        $wl = [string](Get-PpdfPathValue $rec @('Workload', 'Application'))
        if (-not $wl) { $wl = 'unknown' }
        $perWorkload[$wl] = 1 + [int](Get-PpdfValue $perWorkload $wl 0)
    }
    $maxPerDay = 0; foreach ($v in $perDay.Values) { $maxPerDay = [Math]::Max($maxPerDay, [int]$v) }
    $maxPerRule = 0; foreach ($v in $perRule.Values) { $maxPerRule = [Math]::Max($maxPerRule, [int]$v) }
    # Scalar metric names follow the threshold convention: maxMatchesPerDay -> matchesPerDay (peak day), etc.
    return [ordered]@{
        totalMatches        = $records.Count
        matchesPerDay       = $maxPerDay
        distinctUsers       = $users.Count
        matchesPerRule      = $maxPerRule
        distributionSuccess = (Get-PpdfDistributionSuccess -Cmdlet 'Get-DlpCompliancePolicy' -Identity $Target.Target)
        ruleBreakdown       = $perRule
        workloadBreakdown   = $perWorkload
    }
} -Export {
    param($Context)
    $rules = @(Invoke-PpdfCmdlet -Name 'Get-DlpComplianceRule')
    foreach ($p in @(Invoke-PpdfCmdlet -Name 'Get-DlpCompliancePolicy')) {
        $name = [string]$p.Name
        if ($name -like "*$($script:DlpShadowSuffix)") { continue }
        $state = ConvertTo-PpdfDlpPolicyState $p
        $text = (Split-PpdfTaggedText ([string]$state.Comment)).Text
        $spec = [ordered]@{ comment = $text; mode = [string]$state.Mode; locations = [ordered]@{}; rules = @() }
        foreach ($k in $state.Keys) { if ((Test-PpdfLocationKey $k) -and @($state[$k]).Count) { $spec.locations[$k] = @($state[$k]) } }
        $spec.rules = @(foreach ($r in ($rules | Where-Object { [string]$_.ParentPolicyName -eq $name })) {
                $rs = ConvertTo-PpdfDlpRuleState $r
                $params = [ordered]@{}
                foreach ($k in $rs.Keys) {
                    if ($k -in 'Name', 'Parent', 'Comment', 'Disabled', 'ParentPolicyName', 'Policy', 'Priority', 'Mode', 'IsValid') { continue }
                    $v = $rs[$k]
                    if ($null -eq $v -or ($v -is [string] -and $v -eq '') -or ((Test-PpdfList $v) -and @($v).Count -eq 0) -or $v -eq $false) { continue }
                    $params[$k] = $v
                }
                [ordered]@{ name = $rs.Name; comment = (Split-PpdfTaggedText ([string]$rs.Comment)).Text; disabled = [bool]$rs.Disabled; parameters = $params }
            })
        @{ Name = $name; Doc = (New-PpdfExportDocument -Kind 'DlpPolicy' -Name $name -Spec $spec -Description 'Exported. Review rule parameters before committing: exports include read-only properties.'); Files = @{} }
    }
}

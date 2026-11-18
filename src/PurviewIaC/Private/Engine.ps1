function Get-PpdfWorkloadRole {
    param([string]$Workload)
    foreach ($k in $script:Kinds.Values) { if ($k.Workload -eq $Workload) { return $k.IdentityRole } }
    return $Workload
}

function Get-PpdfCurrent {
    <#
    .SYNOPSIS
    Reads the current state of a desired object and separates the ppdf ownership tag from the tagged property.
    #>
    param($TypeDef, $Desired, $Context)
    $raw = & $TypeDef.Get $Desired $Context
    if ($null -eq $raw) { return @{ Exists = $false; Current = $null; Tag = $null; Text = $null } }
    $current = [ordered]@{}
    foreach ($k in $raw.Keys) { $current[$k] = $raw[$k] }
    $tag = $null
    $text = $null
    if ($TypeDef.TagProperty) {
        $split = Split-PpdfTaggedText ([string](Get-PpdfValue $current $TypeDef.TagProperty))
        $tag = $split.Tag
        $text = $split.Text
        foreach ($k in @($current.Keys)) { if ([string]::Equals($k, $TypeDef.TagProperty, [StringComparison]::OrdinalIgnoreCase)) { $current[$k] = $text } }
    }
    return @{ Exists = $true; Current = $current; Tag = $tag; Text = $text }
}

function Get-PpdfExpectedState {
    param($TypeDef, $Desired, $Current)
    $keys = @($Desired.Properties.Keys | ForEach-Object { [string]$_ }) + @($TypeDef.KnownProperties)
    return (Get-PpdfProjection -Current $Current -Keys $keys)
}

function New-PpdfAction {
    param([string]$Op, $Desired, $TypeDef, $Artifact, $Kind, [string]$Stage, [string]$TagId, $State, [string[]]$DiffKeys = @(), [string]$Source = 'artifact')
    $workload = if ($Kind) { $Kind.Workload } else { $TypeDef.Workload }
    $role = if ($Kind) { $Kind.IdentityRole } else { Get-PpdfWorkloadRole $TypeDef.Workload }
    $expected = if ($State.Exists) { Get-PpdfExpectedState -TypeDef $TypeDef -Desired $Desired -Current $State.Current } else { $null }
    return [ordered]@{
        id             = $null
        op             = $Op
        source         = $Source
        type           = $TypeDef.Name
        name           = $Desired.Name
        parent         = $Desired.Parent
        order          = [int]$Desired.Order
        primary        = [bool]$Desired.Primary
        kind           = if ($Kind) { $Kind.Name } else { $null }
        artifactId     = if ($Artifact) { $Artifact.Id } else { $TagId }
        tagId          = $TagId
        artifactSha    = if ($Artifact) { $Artifact.Sha } else { $null }
        workload       = $workload
        identityRole   = $role
        service        = $TypeDef.Service
        stage          = $Stage
        diffKeys       = @($DiffKeys)
        desired        = $Desired.Properties
        options        = $Desired.Options
        expected       = $expected
        expectAbsent   = (-not $State.Exists)
        fingerprint    = if ($State.Exists) { Get-PpdfHash $expected } else { 'absent' }
        currentTag     = $State.Tag
        tier           = 'low'
        reasons        = @()
        blocked        = $false
        blockedReasons = @()
    }
}

function Add-PpdfRisk {
    param($Action, [string]$Tier, [string]$Reason, [switch]$Block)
    $Action.tier = Get-PpdfMaxTier @($Action.tier, $Tier)
    if ($Reason) { $Action.reasons = @($Action.reasons) + $Reason }
    if ($Block) { $Action.blocked = $true; $Action.blockedReasons = @($Action.blockedReasons) + $Reason }
}

function Invoke-PpdfAssess {
    param($Action, $Kind, $Artifact, $Context)
    switch ($Action.op) {
        'create' { Add-PpdfRisk $Action 'standard' }
        'update' { Add-PpdfRisk $Action 'standard' }
        'adopt' { Add-PpdfRisk $Action 'elevated' 'Adopting an existing unmanaged object.' }
        'delete' {
            if ($Action.parent) { Add-PpdfRisk $Action 'elevated' 'Deletes a child object.' }
            else { Add-PpdfRisk $Action 'critical' 'Deletes a top-level object.' }
        }
    }
    if ($Action.stage -eq 'enforce' -and $Action.op -in 'create', 'update', 'adopt' -and $Kind -and $Kind.SimulationStrategy -eq 'mode') {
        Add-PpdfRisk $Action 'elevated' 'Enforcing change.'
    }
    if ($Artifact) {
        $min = Get-PpdfValue $Artifact.Doc.metadata 'riskTier'
        if ($min) { Add-PpdfRisk $Action $min "Artifact minimum risk tier '$min'." }
    }
    if ($Kind -and $Kind.Assess) {
        $r = & $Kind.Assess $Action $Artifact $Context
        foreach ($x in @($r)) {
            if (-not $x) { continue }
            Add-PpdfRisk $Action ([string](Get-PpdfValue $x 'Tier' 'low')) ([string](Get-PpdfValue $x 'Reason')) -Block:([bool](Get-PpdfValue $x 'Block' $false))
        }
    }
}

function Test-PpdfSimulationEvidence {
    <#
    .SYNOPSIS
    Validates a simulation report for use as promotion evidence. Returns @{ Valid; Errors; Report; Hash }.
    #>
    param([string]$Path, $Context)
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{ Valid = $false; Errors = @('Simulation report not provided or not found.'); Report = $null; Hash = $null } }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $report = Read-PpdfJson -Path $Path
    if ((Get-PpdfValue $report 'type') -ne 'ppdf-simulation-report') { $errors.Add('File is not a ppdf simulation report.') }
    if ((Get-PpdfValue $report 'environment') -ne $Context.EnvName) { $errors.Add("Report environment '$($report.environment)' does not match '$($Context.EnvName)'.") }
    $sidecar = "$Path.sha256"
    if (Test-Path -LiteralPath $sidecar) {
        $expected = (Get-Content -LiteralPath $sidecar -Raw).Trim().Split(' ')[0].ToLowerInvariant()
        if ($expected -ne $hash) { $errors.Add('Simulation report hash does not match its .sha256 sidecar (report modified).') }
    }
    $maxAge = [double](Get-PpdfValue (Get-PpdfValue $Context.Env 'simulation' @{}) 'maxReportAgeHours' 168)
    $created = Get-PpdfValue $report 'createdUtc'
    if ($created) {
        $createdDt = if ($created -is [datetime]) { $created.ToUniversalTime() } else { [datetime]::Parse([string]$created, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal) }
        if (((Get-Date).ToUniversalTime() - $createdDt).TotalHours -gt $maxAge) { $errors.Add("Simulation report is older than $maxAge hours.") }
    }
    return @{ Valid = ($errors.Count -eq 0); Errors = $errors.ToArray(); Report = $report; Hash = $hash }
}

function Get-PpdfSortedObject {
    param($Objects)
    return @($Objects | Sort-Object -Property @{ Expression = { [int]$_.Order } }, @{ Expression = { [string]$_.Name } })
}

function Build-PpdfPlan {
    <#
    .SYNOPSIS
    Core planner: expands artifacts into desired objects, reads current state, resolves ownership, diffs,
    assesses risk, detects orphans and applies the simulation evidence gate.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('simulate', 'enforce', 'auto')][string]$Stage = 'simulate',
        [string]$SimulationReportPath
    )
    $actions = [System.Collections.Generic.List[object]]::new()
    $artifactSummaries = [System.Collections.Generic.List[object]]::new()
    $desiredKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $noop = 0
    $allowDestructive = [bool](Get-PpdfValue $Context.Env 'allowDestructive' $false)

    $evidence = $null
    if ($Stage -eq 'enforce') {
        $needEvidence = @($Context.Artifacts | Where-Object { $script:Kinds[$_.Kind].RequiresSimulationEvidence }).Count -gt 0
        if ($needEvidence) { $evidence = Test-PpdfSimulationEvidence -Path $SimulationReportPath -Context $Context }
    }

    foreach ($a in $Context.Artifacts) {
        $kind = $script:Kinds[$a.Kind]
        $meta = $a.Doc.metadata
        $ensure = [string](Get-PpdfValue $meta 'ensure' 'present')
        $adopt = [bool](Get-PpdfValue $meta 'adopt' $false)
        $simSkip = [bool](Get-PpdfValue (Get-PpdfValue $a.Doc 'simulation' @{}) 'skip' $false)
        $summary = [ordered]@{ id = $a.Id; kind = $a.Kind; name = $a.Name; sha = $a.Sha; path = $a.RelativePath; stage = $null; status = 'planned'; notes = @() }

        $probe = @(& $kind.Expand $a $Context 'enforce' $false)
        foreach ($o in $probe) { [void]$desiredKeys.Add("$($o.Type)|$($o.Name)") }
        $primaryDesired = @($probe | Where-Object { $_.Primary })
        if ($primaryDesired.Count -eq 0) { $primaryDesired = @($probe | Where-Object { -not $_.Parent }) }
        $primaryDesired = $primaryDesired[0]
        $primaryType = Get-PpdfObjectType $primaryDesired.Type
        $primaryState = Get-PpdfCurrent -TypeDef $primaryType -Desired $primaryDesired -Context $Context
        $primaryOwned = $primaryState.Exists -and (-not $primaryType.TagProperty -or ($primaryState.Tag -and $primaryState.Tag.id -eq $a.Id))
        $primaryStage = if ($primaryOwned -and $primaryState.Tag) { [string]$primaryState.Tag.stage } else { $null }

        $effStage = $Stage
        $shadow = $false
        if ($Stage -eq 'auto') {
            # Keep objects at their deployed stage. A live object without a PPDF tag (being adopted) is treated as
            # enforced so adoption never switches it to test mode.
            $effStage = if ($primaryStage) { $primaryStage }
            elseif ($primaryState.Exists -and $primaryType.TagProperty -and -not $primaryState.Tag) { 'enforce' }
            else { 'simulate' }
        }
        elseif ($Stage -eq 'simulate' -and $ensure -ne 'absent') {
            if ($kind.SimulationStrategy -eq 'whatif') {
                $summary.status = 'deferred'; $summary.notes = @('No simulation equivalent; changes are planned (what-if) and applied at the enforce stage after approval.')
            }
            elseif ($simSkip) {
                $summary.status = 'deferred'; $summary.notes = @('simulation.skip is set; changes are applied at the enforce stage with critical approval.')
            }
            elseif ($kind.SimulationStrategy -eq 'mode' -and ($primaryStage -eq 'enforce' -or ($primaryState.Exists -and $primaryType.TagProperty -and -not $primaryState.Tag))) {
                # Never downgrade a live (enforced or pre-existing unmanaged) object to simulation in place.
                if ($kind.SupportsShadow) { $shadow = $true; $summary.notes = @('Object is live; simulating changes in a shadow copy.') }
                else { $summary.status = 'deferred'; $summary.notes = @('Object is live and cannot be shadowed; changes are applied at the enforce stage with elevated approval.') }
            }
        }
        $summary.stage = $effStage
        if ($summary.status -eq 'deferred') {
            # Still compute the what-if so reviewers see the pending change, but do not apply it in this stage.
            $whatIf = @(& $kind.Expand $a $Context 'enforce' $false)
            foreach ($d in (Get-PpdfSortedObject $whatIf)) {
                $td = Get-PpdfObjectType $d.Type
                $st = if ($d.Type -eq $primaryDesired.Type -and $d.Name -eq $primaryDesired.Name) { $primaryState } else { Get-PpdfCurrent -TypeDef $td -Desired $d -Context $Context }
                if (-not $st.Exists) { $summary.notes = @($summary.notes) + "what-if: create $($d.Type) '$($d.Name)'"; continue }
                $dk = Compare-PpdfProperty -Desired $d.Properties -Current $st.Current -Ignore (Get-PpdfIgnoreList $td $d)
                if ($dk.Count) { $summary.notes = @($summary.notes) + "what-if: update $($d.Type) '$($d.Name)' ($($dk -join ', '))" }
            }
            $artifactSummaries.Add($summary)
            continue
        }

        $tagId = if ($shadow) { "$($a.Id)#sim" } else { $a.Id }
        $objects = @(if ($shadow -or $effStage -ne 'enforce') { & $kind.Expand $a $Context $effStage $shadow } else { $probe })
        if ($ensure -eq 'absent') { $objects = @($probe | Where-Object { -not $_.Parent }) }
        foreach ($o in $objects) { [void]$desiredKeys.Add("$($o.Type)|$($o.Name)") }

        foreach ($d in (Get-PpdfSortedObject $objects)) {
            $td = Get-PpdfObjectType $d.Type
            $state = if (-not $shadow -and $d.Type -eq $primaryDesired.Type -and $d.Name -eq $primaryDesired.Name) { $primaryState } else { Get-PpdfCurrent -TypeDef $td -Desired $d -Context $Context }

            $ownership = 'absent'
            if ($state.Exists) {
                if (-not $td.TagProperty) { $ownership = 'managed' }
                elseif ($state.Tag -and $state.Tag.id -eq $tagId) { $ownership = 'managed' }
                elseif ($state.Tag) { $ownership = 'foreign' }
                else { $ownership = 'unmanaged' }
            }

            if ($ensure -eq 'absent') {
                if (-not $state.Exists) { $noop++; continue }
                $act = New-PpdfAction -Op 'delete' -Desired $d -TypeDef $td -Artifact $a -Kind $kind -Stage $effStage -TagId $tagId -State $state -Source 'absent'
                Invoke-PpdfAssess -Action $act -Kind $kind -Artifact $a -Context $Context
                if ($ownership -eq 'foreign') { Add-PpdfRisk $act 'critical' "Object is owned by another artifact ($($state.Tag.id))." -Block }
                $actions.Add($act)
                continue
            }

            $diff = @()
            $op = 'create'
            if ($state.Exists) {
                $diff = @(Compare-PpdfProperty -Desired $d.Properties -Current $state.Current -Ignore (Get-PpdfIgnoreList $td $d))
                $isPrimary = $d.Primary -or (-not @($objects | Where-Object { $_.Primary }).Count -and -not $d.Parent)
                if ($ownership -eq 'managed' -and $isPrimary -and $td.TagProperty -and $state.Tag -and
                    ([string]$state.Tag.sha -ne $a.Sha.Substring(0, 8) -or [string]$state.Tag.stage -ne $effStage) -and $td.TagProperty -notin $diff) {
                    # Re-stamp the ownership tag so simulation evidence and drift track the current artifact version/stage.
                    $diff += $td.TagProperty
                }
                $op = switch ($ownership) {
                    'managed' { if ($diff.Count) { 'update' } else { 'noop' } }
                    'unmanaged' { 'adopt' }
                    default { 'update' }
                }
            }
            if ($op -eq 'noop') { $noop++; continue }
            $act = New-PpdfAction -Op $op -Desired $d -TypeDef $td -Artifact $a -Kind $kind -Stage $effStage -TagId $tagId -State $state -DiffKeys $diff
            Invoke-PpdfAssess -Action $act -Kind $kind -Artifact $a -Context $Context
            if ($ownership -eq 'foreign') { Add-PpdfRisk $act 'critical' "Object is owned by another artifact ($($state.Tag.id)); refusing to modify." -Block }
            if ($ownership -eq 'unmanaged' -and -not $adopt) { Add-PpdfRisk $act 'elevated' "Object exists but is not managed by PPDF. Set metadata.adopt: true to take ownership." -Block }
            if ($effStage -eq 'enforce' -and $Stage -eq 'enforce' -and $kind.RequiresSimulationEvidence) {
                if ($simSkip) { Add-PpdfRisk $act 'critical' 'simulation.skip is set: promoting without simulation evidence.' }
                elseif (-not $evidence -or -not $evidence.Valid) { Add-PpdfRisk $act 'critical' ("No valid simulation evidence: " + (@($evidence.Errors) -join '; ')) -Block }
                else {
                    $entry = @($evidence.Report.artifacts | Where-Object { $_.id -eq $a.Id })
                    if ($entry.Count -eq 0) { Add-PpdfRisk $act 'critical' 'Artifact not present in the simulation report.' -Block }
                    elseif ($entry[0].sha -ne $a.Sha) { Add-PpdfRisk $act 'critical' 'Artifact changed since it was simulated (sha mismatch). Re-run the simulation.' -Block }
                    elseif ($entry[0].status -eq 'deferred') { Add-PpdfRisk $act 'elevated' 'Change could not be simulated (deferred); elevated approval required.' }
                    elseif ($entry[0].status -notin 'pass', 'already-enforced') { Add-PpdfRisk $act 'critical' "Simulation status is '$($entry[0].status)'." -Block }
                }
            }
            $actions.Add($act)
        }
        $artifactSummaries.Add($summary)
    }

    # Orphans: objects carrying a ppdf tag that no longer correspond to any desired object.
    $selectedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Context.Artifacts) { [void]$selectedIds.Add($a.Id); [void]$selectedIds.Add("$($a.Id)#sim") }
    $deletedParents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($act in $actions) { if ($act.op -eq 'delete' -and -not $act.parent) { [void]$deletedParents.Add($act.name) } }
    $orphans = [System.Collections.Generic.List[object]]::new()
    foreach ($td in @($script:ObjectTypes.Values | Sort-Object { $_.Name })) {
        if (-not $td.ListManaged -or $td.Workload -notin $Context.Workloads) { continue }
        foreach ($raw in @(& $td.ListManaged $Context)) {
            if ($null -eq $raw) { continue }
            $split = Split-PpdfTaggedText ([string](Get-PpdfValue $raw $td.TagProperty))
            if (-not $split.Tag -or -not $split.Tag.id) { continue }
            $name = [string](Get-PpdfValue $raw 'Name')
            if ($desiredKeys.Contains("$($td.Name)|$name")) { continue }
            if ($Context.Filtered -and -not $selectedIds.Contains($split.Tag.id)) { continue }
            $orphans.Add(@{ TypeDef = $td; Raw = $raw; Tag = $split.Tag; Text = $split.Text; Name = $name; Parent = [string](Get-PpdfValue $raw 'Parent') })
        }
    }
    foreach ($o in ($orphans | Sort-Object { if ($_.Parent) { 1 } else { 0 } })) {
        if ($o.Parent -and $deletedParents.Contains($o.Parent)) { continue }
        $current = [ordered]@{}
        foreach ($k in $o.Raw.Keys) { $current[$k] = $o.Raw[$k] }
        $current[$o.TypeDef.TagProperty] = $o.Text
        $d = New-PpdfDesiredObject -Type $o.TypeDef.Name -Name $o.Name -Parent $o.Parent -Order 1000 -Options ([ordered]@{ Policy = $o.Parent })
        $state = @{ Exists = $true; Current = $current; Tag = $o.Tag; Text = $o.Text }
        $act = New-PpdfAction -Op 'delete' -Desired $d -TypeDef $o.TypeDef -Stage ([string]$o.Tag.stage) -TagId ([string]$o.Tag.id) -State $state -Source 'orphan'
        $act.artifactId = ([string]$o.Tag.id) -replace '#sim$', ''
        if ([string]$o.Tag.id -like '*#sim') { Add-PpdfRisk $act 'standard' 'Removes a shadow simulation copy that is no longer needed.' }
        elseif ($o.Parent) { Add-PpdfRisk $act 'elevated' "Orphaned child object (artifact '$($o.Tag.id)' no longer declares it)." }
        else {
            Add-PpdfRisk $act 'critical' "Orphaned object (artifact '$($o.Tag.id)' was removed from config)."
            if (-not $allowDestructive) { Add-PpdfRisk $act 'critical' 'Deleting orphaned top-level objects requires spec.allowDestructive: true or an explicit metadata.ensure: absent artifact.' -Block }
            [void]$deletedParents.Add($o.Name)
        }
        $actions.Add($act)
    }

    $i = 0
    foreach ($act in $actions) { $i++; $act.id = '{0:d3}' -f $i }
    return @{ Actions = $actions.ToArray(); Artifacts = $artifactSummaries.ToArray(); Noop = $noop; Evidence = $evidence }
}

function New-PpdfPlanDocument {
    param($Context, $Result, [string]$Stage, [string]$SimulationReportPath, [string]$RollbackOf)
    $acts = @($Result.Actions)
    $blocked = @($acts | Where-Object { $_.blocked })
    $tier = if ($acts.Count) { Get-PpdfMaxTier @($acts | ForEach-Object { $_.tier }) } else { 'low' }
    if ($RollbackOf) { $tier = Get-PpdfMaxTier @($tier, 'elevated') }
    $approvals = Get-PpdfValue $Context.Env 'approvals' @{}
    $envMap = Get-PpdfValue $approvals 'environments' @{}
    $approvalEnv = Get-PpdfValue $envMap $tier
    if (-not $approvalEnv) {
        $pattern = [string](Get-PpdfValue $approvals 'pattern' '{env}-{tier}')
        $approvalEnv = $pattern.Replace('{env}', $Context.EnvName).Replace('{tier}', $tier)
    }
    $tenant = Get-PpdfValue $Context.Env 'tenant' @{}
    return [ordered]@{
        type                 = 'ppdf-plan'
        schemaVersion        = 1
        environment          = $Context.EnvName
        tenantId             = [string](Get-PpdfValue $tenant 'tenantId')
        stage                = $Stage
        rollbackOf           = $RollbackOf
        createdUtc           = (Get-Date).ToUniversalTime().ToString('o')
        engineVersion        = Get-PpdfEngineVersion
        orchestrator         = if ($script:Run) { $script:Run.orchestrator } else { Get-PpdfOrchestrator }
        configHash           = $Context.ConfigHash
        environmentSpec      = $Context.Env
        simulationReport     = if ($Result.Evidence) { [ordered]@{ path = $SimulationReportPath; hash = $Result.Evidence.Hash; valid = $Result.Evidence.Valid; errors = @($Result.Evidence.Errors) } } else { $null }
        summary              = [ordered]@{
            create   = @($acts | Where-Object { $_.op -eq 'create' }).Count
            update   = @($acts | Where-Object { $_.op -eq 'update' }).Count
            adopt    = @($acts | Where-Object { $_.op -eq 'adopt' }).Count
            delete   = @($acts | Where-Object { $_.op -eq 'delete' }).Count
            noop     = [int]$Result.Noop
            blocked  = $blocked.Count
            deferred = @($Result.Artifacts | Where-Object { $_.status -eq 'deferred' }).Count
        }
        requiredApprovalTier = $tier
        approvalEnvironment  = $approvalEnv
        artifacts            = @($Result.Artifacts)
        actions              = $acts
    }
}

function Save-PpdfDocument {
    <#
    .SYNOPSIS
    Writes a JSON document plus a .sha256 sidecar; returns the file hash.
    #>
    param($Document, [string]$Path)
    Write-PpdfJson -InputObject $Document -Path $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$Path.sha256" -Value "$hash  $(Split-Path -Leaf $Path)" -Encoding utf8NoBOM
    return $hash
}

function ConvertTo-PpdfPlanMarkdown {
    param($Plan, [string]$Hash)
    $sb = [System.Text.StringBuilder]::new()
    $title = if ($Plan.rollbackOf) { 'Rollback plan' } else { 'Plan' }
    [void]$sb.AppendLine("## Purview $title - ``$($Plan.environment)`` ($($Plan.stage))")
    [void]$sb.AppendLine()
    $s = $Plan.summary
    [void]$sb.AppendLine("| create | update | adopt | delete | no-op | blocked | deferred | approval tier | approval environment |")
    [void]$sb.AppendLine("|---|---|---|---|---|---|---|---|---|")
    [void]$sb.AppendLine("| $($s.create) | $($s.update) | $($s.adopt) | $($s.delete) | $($s.noop) | $($s.blocked) | $($s.deferred) | **$($Plan.requiredApprovalTier)** | ``$($Plan.approvalEnvironment)`` |")
    [void]$sb.AppendLine()
    if ($Hash) { [void]$sb.AppendLine("Plan hash: ``$Hash``  ") }
    [void]$sb.AppendLine("Config hash: ``$($Plan.configHash)``  ")
    if ($Plan.simulationReport) { [void]$sb.AppendLine("Simulation evidence: ``$($Plan.simulationReport.hash)`` valid=$($Plan.simulationReport.valid)  ") }
    [void]$sb.AppendLine()
    $acts = @($Plan.actions)
    if ($acts.Count) {
        [void]$sb.AppendLine('### Actions')
        [void]$sb.AppendLine('| # | op | type | name | artifact | stage | tier | changed | notes |')
        [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|')
        foreach ($a in $acts) {
            $flag = if ($a.blocked) { ':no_entry: ' } else { '' }
            $notes = (@($a.reasons) + @($a.blockedReasons | ForEach-Object { "BLOCKED: $_" }) | Select-Object -Unique) -join '<br>'
            [void]$sb.AppendLine("| $($a.id) | $flag$($a.op) | $($a.type) | $($a.name) | $($a.artifactId) | $($a.stage) | $($a.tier) | $(@($a.diffKeys) -join ', ') | $notes |")
        }
        [void]$sb.AppendLine()
    }
    else { [void]$sb.AppendLine('_No changes._'); [void]$sb.AppendLine() }
    $notes = @($Plan.artifacts | Where-Object { @($_.notes).Count -gt 0 })
    if ($notes.Count) {
        [void]$sb.AppendLine('### Artifact notes')
        foreach ($n in $notes) {
            [void]$sb.AppendLine("- **$($n.id)** ($($n.status)):")
            foreach ($x in @($n.notes)) { [void]$sb.AppendLine("  - $x") }
        }
    }
    return $sb.ToString()
}

function Get-PpdfAdapterContext {
    param($Plan)
    return [ordered]@{ EnvName = $Plan.environment; Env = $Plan.environmentSpec; Stage = $Plan.stage; Workloads = @(); Artifacts = @() }
}

function ConvertTo-PpdfDesiredFromAction {
    param($Action, [switch]$WithTag)
    $props = [ordered]@{}
    if ($Action.desired) { foreach ($k in $Action.desired.Keys) { $props[$k] = $Action.desired[$k] } }
    $td = Get-PpdfObjectType $Action.type
    if ($WithTag -and $td.TagProperty) {
        $text = [string](Get-PpdfValue $props $td.TagProperty)
        $sha = if ($Action.artifactSha) { [string]$Action.artifactSha } else { 'rollback' }
        $props[$td.TagProperty] = Join-PpdfTaggedText -Text $text -Tag (Format-PpdfTag -Id $Action.tagId -Sha $sha -Stage $Action.stage)
    }
    $opts = [ordered]@{}
    if ($Action.options) { foreach ($k in $Action.options.Keys) { $opts[$k] = $Action.options[$k] } }
    return [ordered]@{ Type = $Action.type; Name = $Action.name; Parent = $Action.parent; Order = $Action.order; Properties = $props; Options = $opts; Primary = $Action.primary }
}

function Test-PpdfActionFresh {
    <#
    .SYNOPSIS
    Verifies the tenant still matches what the plan saw (optimistic concurrency).
    #>
    param($Action, $Context)
    $td = Get-PpdfObjectType $Action.type
    $d = ConvertTo-PpdfDesiredFromAction -Action $Action
    $state = Get-PpdfCurrent -TypeDef $td -Desired $d -Context $Context
    if ($Action.expectAbsent) { return @{ Fresh = (-not $state.Exists); State = $state; Reason = 'object now exists' } }
    if (-not $state.Exists) { return @{ Fresh = $false; State = $state; Reason = 'object no longer exists' } }
    $planTagId = if ($Action.currentTag) { [string](Get-PpdfValue $Action.currentTag 'id') } else { $null }
    $nowTagId = if ($state.Tag) { [string]$state.Tag.id } else { $null }
    if ($planTagId -ne $nowTagId) { return @{ Fresh = $false; State = $state; Reason = "ownership tag changed ('$planTagId' -> '$nowTagId')" } }
    if ($Action.expected -and -not (Test-PpdfValueMatch -Desired $Action.expected -Current $state.Current)) { return @{ Fresh = $false; State = $state; Reason = 'object changed since plan' } }
    return @{ Fresh = $true; State = $state; Reason = $null }
}

function Invoke-PpdfAction {
    param($Action, $State, $Context)
    $td = Get-PpdfObjectType $Action.type
    $d = ConvertTo-PpdfDesiredFromAction -Action $Action -WithTag
    switch ($Action.op) {
        'create' { & $td.Create $d $Context | Out-Null }
        { $_ -in 'update', 'adopt' } {
            $keys = @($Action.diffKeys)
            if ($td.TagProperty -and $td.TagProperty -notin $keys) { $keys += $td.TagProperty }
            & $td.Update $d $State.Current $keys $Context | Out-Null
        }
        'delete' { & $td.Remove $d $State.Current $Context | Out-Null }
    }
}

function Get-PpdfActionPhase {
    param($Action)
    if ($Action.op -eq 'delete' -and $Action.parent) { return 0 }
    if ($Action.op -eq 'delete') { return 2 }
    return 1
}

function Invoke-PpdfPlanApply {
    <#
    .SYNOPSIS
    Applies plan actions grouped by identity role, after verifying freshness for every action in the group.
    #>
    param($Plan, [string[]]$Workload)
    $ctx = Get-PpdfAdapterContext -Plan $Plan
    $results = [System.Collections.Generic.List[object]]::new()
    $acts = @($Plan.actions | Where-Object { -not $Workload -or $_.workload -in $Workload })
    $exit = 0
    $halted = $false
    $groups = $acts | Group-Object -Property { $_.identityRole }
    foreach ($g in $groups) {
        if ($halted) {
            foreach ($a in $g.Group) { $results.Add([ordered]@{ id = $a.id; op = $a.op; type = $a.type; name = $a.name; workload = $a.workload; status = 'not-run' }) }
            continue
        }
        $services = @($g.Group | ForEach-Object { $_.service } | Select-Object -Unique)
        Connect-PpdfIdentity -Role $g.Name -EnvSpec $Plan.environmentSpec -Services $services
        $states = @{}
        $stale = @()
        foreach ($a in $g.Group) {
            $f = Test-PpdfActionFresh -Action $a -Context $ctx
            $states[$a.id] = $f.State
            if (-not $f.Fresh) { $stale += "$($a.id) $($a.type) '$($a.name)': $($f.Reason)" }
        }
        if ($stale.Count) {
            foreach ($s in $stale) { Write-PpdfLog -Level error -Message "Stale plan: $s" }
            foreach ($a in $g.Group) { $results.Add([ordered]@{ id = $a.id; op = $a.op; type = $a.type; name = $a.name; workload = $a.workload; status = 'skipped-stale' }) }
            $exit = 3
            continue
        }
        $ordered = $g.Group | Sort-Object -Property @{ Expression = { Get-PpdfActionPhase $_ } }, @{ Expression = { if ($_.op -eq 'delete') { - [int]$_.order } else { [int]$_.order } } }, @{ Expression = { $_.id } }
        $failed = $false
        foreach ($a in $ordered) {
            if ($failed) { $results.Add([ordered]@{ id = $a.id; op = $a.op; type = $a.type; name = $a.name; workload = $a.workload; status = 'not-run' }); continue }
            try {
                Write-PpdfLog -Message "[$($a.id)] $($a.op) $($a.type) '$($a.name)'"
                Invoke-PpdfAction -Action $a -State $states[$a.id] -Context $ctx
                $results.Add([ordered]@{ id = $a.id; op = $a.op; type = $a.type; name = $a.name; workload = $a.workload; status = 'succeeded'; utc = (Get-Date).ToUniversalTime().ToString('o') })
            }
            catch {
                Write-PpdfLog -Level error -Message "[$($a.id)] $($a.op) $($a.type) '$($a.name)' failed: $($_.Exception.Message)"
                $results.Add([ordered]@{ id = $a.id; op = $a.op; type = $a.type; name = $a.name; workload = $a.workload; status = 'failed'; error = $_.Exception.Message })
                $failed = $true
                $exit = 1
            }
        }
        if ($failed) { $halted = $true }
    }
    Disconnect-PpdfIdentity
    return @{ ExitCode = $exit; Results = $results.ToArray() }
}

function New-PpdfEvidenceBundle {
    param([string]$OutputPath, [string[]]$Files)
    $dir = Join-Path $OutputPath 'evidence'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $manifest = [ordered]@{ type = 'ppdf-evidence'; createdUtc = (Get-Date).ToUniversalTime().ToString('o'); orchestrator = $script:Run.orchestrator; files = [ordered]@{} }
    foreach ($f in $Files) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        $leaf = Split-Path -Leaf $f
        $dest = Join-Path $dir $leaf
        if ((Resolve-Path $f).Path -ne [System.IO.Path]::GetFullPath($dest)) { Copy-Item -LiteralPath $f -Destination $dest -Force }
        $manifest.files[$leaf] = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Save-PpdfDocument -Document $manifest -Path (Join-Path $dir 'manifest.json') | Out-Null
    return $dir
}

function New-PpdfRollbackAction {
    <#
    .SYNOPSIS
    Builds inverse actions for the successfully applied actions of a plan.
    #>
    param($Plan, $ApplyResult)
    $succeeded = @{}
    foreach ($r in @($ApplyResult.results)) { if ($r.status -eq 'succeeded') { $succeeded[$r.id] = $true } }
    $inverse = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($Plan.actions)) {
        if (-not $succeeded.ContainsKey($a.id)) { continue }
        $td = Get-PpdfObjectType $a.type
        $inv = [ordered]@{}
        foreach ($k in $a.Keys) { $inv[$k] = $a[$k] }
        $inv.source = 'rollback'
        $inv.artifactSha = 'rollback'
        $inv.reasons = @("Rollback of action $($a.id) ($($a.op)).")
        $inv.blocked = $false
        $inv.blockedReasons = @()
        $inv.tier = 'elevated'
        $desiredNoTag = [ordered]@{}
        foreach ($k in $a.desired.Keys) { if ($k -ne $td.TagProperty) { $desiredNoTag[$k] = $a.desired[$k] } }
        $prevStage = if ($a.currentTag) { [string](Get-PpdfValue $a.currentTag 'stage' $a.stage) } else { $a.stage }
        switch ($a.op) {
            'create' {
                $inv.op = 'delete'; $inv.expected = $desiredNoTag; $inv.expectAbsent = $false
                $inv.currentTag = [ordered]@{ id = $a.tagId }
            }
            { $_ -in 'update', 'adopt' } {
                $old = [ordered]@{}
                foreach ($k in @($a.diffKeys)) { $old[$k] = Get-PpdfValue $a.expected $k }
                if ($td.TagProperty -and (Test-PpdfHasKey $a.expected $td.TagProperty)) { $old[$td.TagProperty] = Get-PpdfValue $a.expected $td.TagProperty }
                $exp = [ordered]@{}
                foreach ($k in @($a.diffKeys)) { $exp[$k] = Get-PpdfValue $desiredNoTag $k }
                $inv.op = 'update'; $inv.desired = $old; $inv.expected = $exp; $inv.expectAbsent = $false; $inv.stage = $prevStage
                $inv.currentTag = [ordered]@{ id = $a.tagId }
                if ($a.op -eq 'adopt') { $inv.reasons = @($inv.reasons) + 'Restores previous values; the object remains tagged as managed.' }
            }
            'delete' {
                $inv.op = 'create'; $inv.desired = $a.expected; $inv.expected = $null; $inv.expectAbsent = $true; $inv.stage = $prevStage
                $inv.currentTag = $null
            }
        }
        $inverse.Add($inv)
    }
    return $inverse.ToArray()
}

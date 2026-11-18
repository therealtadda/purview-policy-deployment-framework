function Get-PpdfThresholdMetricName {
    param([string]$Threshold)
    $m = [regex]::Match($Threshold, '^(max|min|require)(?<rest>.+)$')
    if (-not $m.Success) { return $null }
    $rest = $m.Groups['rest'].Value
    return ($rest.Substring(0, 1).ToLowerInvariant() + $rest.Substring(1))
}

function Test-PpdfThreshold {
    <#
    .SYNOPSIS
    Evaluates threshold rules against metrics. Convention: maxX => metric x <= v, minX => x >= v, requireX => x is true.
    minSoakHours is evaluated against the soakHours metric.
    #>
    param([System.Collections.IDictionary]$Thresholds, [System.Collections.IDictionary]$Metrics)
    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($k in ($Thresholds.Keys | Sort-Object)) {
        $limit = $Thresholds[$k]
        if ($null -eq $limit) { continue }
        $metric = Get-PpdfThresholdMetricName $k
        if (-not $metric) { $checks.Add([ordered]@{ name = $k; threshold = $limit; actual = $null; pass = $false; message = 'Unknown threshold convention.' }); continue }
        if (-not (Test-PpdfHasKey $Metrics $metric)) { $checks.Add([ordered]@{ name = $k; threshold = $limit; actual = $null; pass = $false; message = "Metric '$metric' unavailable." }); continue }
        $actual = Get-PpdfValue $Metrics $metric
        $pass = switch -Regex ($k) {
            '^max' { [double]$actual -le [double]$limit; break }
            '^min' { [double]$actual -ge [double]$limit; break }
            '^require' { if ([bool]$limit) { $actual -eq $true } else { $true }; break }
        }
        $checks.Add([ordered]@{ name = $k; threshold = $limit; actual = $actual; pass = [bool]$pass })
    }
    return , $checks.ToArray()
}

function Get-PpdfEffectiveThreshold {
    param($Artifact, $Context, $Kind)
    $t = [ordered]@{}
    foreach ($k in $Kind.DefaultThresholds.Keys) { $t[$k] = $Kind.DefaultThresholds[$k] }
    $envSim = Get-PpdfValue $Context.Env 'simulation' @{}
    $envT = Get-PpdfValue (Get-PpdfValue $envSim 'thresholds' @{}) $Kind.Name
    if ($envT) { foreach ($k in $envT.Keys) { $t[$k] = $envT[$k] } }
    $minSoak = Get-PpdfValue $envSim 'minSoakHours'
    if ($null -ne $minSoak -and $Kind.SimulationStrategy -eq 'mode') { $t['minSoakHours'] = $minSoak }
    $artT = Get-PpdfValue (Get-PpdfValue $Artifact.Doc 'simulation' @{}) 'thresholds'
    if ($artT) { foreach ($k in $artT.Keys) { $t[$k] = $artT[$k] } }
    return $t
}

function ConvertFrom-PpdfTagTimestamp {
    param([string]$Value)
    if (-not $Value) { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) { return $dt }
    return $null
}

function Get-PpdfSimulationTarget {
    <#
    .SYNOPSIS
    Locates the object currently carrying the simulation for an artifact (shadow copy or in-place simulate-stage object).
    #>
    param($Artifact, $Kind, $Context)
    $short = $Artifact.Sha.Substring(0, 8)
    $probe = @(& $Kind.Expand $Artifact $Context 'enforce' $false)
    $primary = @($probe | Where-Object { $_.Primary })[0]
    if (-not $primary) { $primary = @($probe | Where-Object { -not $_.Parent })[0] }
    $td = Get-PpdfObjectType $primary.Type
    $state = Get-PpdfCurrent -TypeDef $td -Desired $primary -Context $Context

    if ($Kind.SimulationStrategy -eq 'corpus') {
        if (-not $state.Exists) { return @{ Status = 'missing'; Note = 'Not deployed. Apply the simulate-stage plan first.' } }
        $diff = @(Compare-PpdfProperty -Desired $primary.Properties -Current $state.Current -Ignore (Get-PpdfIgnoreList $td $primary))
        if ($diff.Count) { return @{ Status = 'stale'; Note = "Deployed version differs from config ($($diff -join ', ')). Apply first." } }
        return @{ Status = 'ready'; Target = $primary.Name; Since = (Get-Date).ToUniversalTime(); Shadow = $false; Primary = $primary }
    }

    if ($Kind.SupportsShadow) {
        $sp = @(& $Kind.Expand $Artifact $Context 'simulate' $true)
        $sprimary = @($sp | Where-Object { $_.Primary })[0]
        if (-not $sprimary) { $sprimary = @($sp | Where-Object { -not $_.Parent })[0] }
        $sstate = Get-PpdfCurrent -TypeDef (Get-PpdfObjectType $sprimary.Type) -Desired $sprimary -Context $Context
        if ($sstate.Exists -and $sstate.Tag -and $sstate.Tag.id -eq "$($Artifact.Id)#sim") {
            if ($sstate.Tag.sha -ne $short) { return @{ Status = 'stale'; Note = "Shadow copy was deployed from sha $($sstate.Tag.sha); config is $short. Re-apply the simulate stage." } }
            return @{ Status = 'ready'; Target = $sprimary.Name; Since = (ConvertFrom-PpdfTagTimestamp $sstate.Tag.ts); Shadow = $true; Primary = $sprimary }
        }
    }
    if (-not $state.Exists) { return @{ Status = 'missing'; Note = 'Not deployed in simulation. Apply the simulate-stage plan first.' } }
    if (-not $state.Tag -or $state.Tag.id -ne $Artifact.Id) {
        if ($Kind.SupportsShadow) { return @{ Status = 'missing'; Note = 'Live unmanaged object; no shadow simulation found.' } }
        return @{ Status = 'deferred'; Note = 'Live unmanaged object without shadow support.' }
    }
    if ($state.Tag.stage -eq 'enforce') {
        if ($state.Tag.sha -eq $short) { return @{ Status = 'already-enforced'; Note = 'Config is already enforced.' } }
        return @{ Status = 'deferred'; Note = 'Enforced object cannot be simulated in place.' }
    }
    if ($state.Tag.sha -ne $short) { return @{ Status = 'stale'; Note = "Simulation was deployed from sha $($state.Tag.sha); config is $short. Re-apply the simulate stage." } }
    return @{ Status = 'ready'; Target = $primary.Name; Since = (ConvertFrom-PpdfTagTimestamp $state.Tag.ts); Shadow = $false; Primary = $primary }
}

function Build-PpdfSimulationReport {
    param($Context)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $Context.Artifacts) {
        $kind = $script:Kinds[$a.Kind]
        $e = [ordered]@{ id = $a.Id; kind = $a.Kind; name = $a.Name; sha = $a.Sha; strategy = $kind.SimulationStrategy; status = $null; target = $null; sinceUtc = $null; soakHours = $null; metrics = $null; checks = @(); notes = @() }
        $sim = Get-PpdfValue $a.Doc 'simulation' @{}
        if ([string](Get-PpdfValue $a.Doc.metadata 'ensure' 'present') -eq 'absent') { $e.status = 'not-applicable'; $e.notes = @('Artifact is being removed.'); $entries.Add($e); continue }
        if ([bool](Get-PpdfValue $sim 'skip' $false)) { $e.status = 'skipped'; $e.notes = @('simulation.skip is set; promotion requires critical approval.'); $entries.Add($e); continue }
        switch ($kind.SimulationStrategy) {
            'whatif' { $e.status = 'deferred'; $e.notes = @('No simulation equivalent: reviewed as a what-if plan and gated by approval.') }
            'none' { $e.status = 'not-applicable'; $e.notes = @('Inert until referenced; no simulation required.') }
            default {
                $t = Get-PpdfSimulationTarget -Artifact $a -Kind $kind -Context $Context
                if ($t.Status -ne 'ready') { $e.status = $t.Status; $e.notes = @($t.Note); break }
                $e.target = $t.Target
                $since = if ($t.Since) { $t.Since } else { (Get-Date).ToUniversalTime() }
                $e.sinceUtc = $since.ToString('o')
                $e.soakHours = [Math]::Round(((Get-Date).ToUniversalTime() - $since).TotalHours, 2)
                $metrics = [ordered]@{}
                if ($kind.SimulationResult) {
                    $m = & $kind.SimulationResult $a $Context @{ Target = $t.Target; Since = $since; Shadow = $t.Shadow; Primary = $t.Primary }
                    if ($m) { foreach ($k in $m.Keys) { $metrics[$k] = $m[$k] } }
                }
                $metrics['soakHours'] = $e.soakHours
                $e.metrics = $metrics
                $thresholds = Get-PpdfEffectiveThreshold -Artifact $a -Context $Context -Kind $kind
                $checks = @(Test-PpdfThreshold -Thresholds $thresholds -Metrics $metrics)
                $e.checks = $checks
                $failed = @($checks | Where-Object { -not $_.pass })
                $soakFail = @($failed | Where-Object { $_.name -eq 'minSoakHours' })
                if ($failed.Count -eq 0) { $e.status = 'pass' }
                elseif ($soakFail.Count -eq $failed.Count) { $e.status = 'soaking'; $e.notes = @("Soak period not complete ($($e.soakHours)h of $($thresholds.minSoakHours)h).") }
                else { $e.status = 'fail' }
            }
        }
        $entries.Add($e)
    }
    $okStatuses = @('pass', 'already-enforced', 'deferred', 'not-applicable', 'skipped')
    $bad = @($entries | Where-Object { $_.status -notin $okStatuses })
    return [ordered]@{
        type         = 'ppdf-simulation-report'
        schemaVersion = 1
        environment  = $Context.EnvName
        createdUtc   = (Get-Date).ToUniversalTime().ToString('o')
        engineVersion = Get-PpdfEngineVersion
        orchestrator = if ($script:Run) { $script:Run.orchestrator } else { $null }
        configHash   = $Context.ConfigHash
        pass         = ($bad.Count -eq 0)
        summary      = [ordered]@{
            total = $entries.Count
            pass = @($entries | Where-Object { $_.status -eq 'pass' }).Count
            fail = @($entries | Where-Object { $_.status -eq 'fail' }).Count
            soaking = @($entries | Where-Object { $_.status -eq 'soaking' }).Count
            missing = @($entries | Where-Object { $_.status -in 'missing', 'stale' }).Count
            other = @($entries | Where-Object { $_.status -in 'already-enforced', 'deferred', 'not-applicable', 'skipped' }).Count
        }
        artifacts    = $entries.ToArray()
    }
}

function ConvertTo-PpdfSimulationMarkdown {
    param($Report, [string]$Hash)
    $sb = [System.Text.StringBuilder]::new()
    $icon = if ($Report.pass) { ':white_check_mark:' } else { ':x:' }
    [void]$sb.AppendLine("## $icon Purview simulation report - ``$($Report.environment)``")
    [void]$sb.AppendLine()
    if ($Hash) { [void]$sb.AppendLine("Report hash: ``$Hash``  ") }
    [void]$sb.AppendLine("Config hash: ``$($Report.configHash)``")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| artifact | strategy | status | target | soak (h) | key metrics | failed checks |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|')
    foreach ($e in @($Report.artifacts)) {
        $metrics = if ($e.metrics) { (@($e.metrics.Keys | Where-Object { $e.metrics[$_] -isnot [System.Collections.IDictionary] -and $e.metrics[$_] -isnot [array] } | ForEach-Object { "$_=$($e.metrics[$_])" }) -join '<br>') } else { '' }
        $failed = (@($e.checks | Where-Object { -not $_.pass } | ForEach-Object { "$($_.name): $($_.actual) vs $($_.threshold)" }) + @($e.notes)) -join '<br>'
        [void]$sb.AppendLine("| $($e.id) | $($e.strategy) | **$($e.status)** | $($e.target) | $($e.soakHours) | $metrics | $failed |")
    }
    return $sb.ToString()
}

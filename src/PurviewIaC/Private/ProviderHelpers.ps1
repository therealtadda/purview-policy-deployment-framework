function Test-PpdfLocationKey {
    param([string]$Key)
    return ($Key -match '(?i)(Location|LocationException)$')
}

function New-PpdfSetParameter {
    <#
    .SYNOPSIS
    Builds Set-* cmdlet parameters for the changed keys. Location lists become Add<Key>/Remove<Key> deltas.
    #>
    param(
        [Parameter(Mandatory)]$Desired,
        $Current,
        [string[]]$DiffKeys,
        [string]$IdentityParameter = 'Identity',
        [string[]]$Exclude = @()
    )
    $p = [ordered]@{ $IdentityParameter = $Desired.Name }
    foreach ($k in $DiffKeys) {
        if ($k -in $Exclude) { continue }
        $v = Get-PpdfValue $Desired.Properties $k
        if (Test-PpdfLocationKey $k) {
            $delta = Get-PpdfListDelta -Desired $v -Current (Get-PpdfValue $Current $k)
            if ($delta.Add.Count) { $p["Add$k"] = [string[]]$delta.Add }
            if ($delta.Remove.Count) { $p["Remove$k"] = [string[]]$delta.Remove }
        }
        else { $p[$k] = ConvertTo-PpdfCmdletValue $v }
    }
    return $p
}

function ConvertTo-PpdfCmdletValue {
    <#
    .SYNOPSIS
    Converts plan values (ordered dictionaries/arrays from JSON) into types S&C cmdlets accept.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if (Test-PpdfDictionary $Value) {
        $h = @{}
        foreach ($k in $Value.Keys) { $h[[string]$k] = ConvertTo-PpdfCmdletValue $Value[$k] }
        return $h
    }
    if (Test-PpdfList $Value) {
        $items = @($Value | ForEach-Object { ConvertTo-PpdfCmdletValue $_ })
        if (@($items | Where-Object { $_ -is [hashtable] }).Count -eq $items.Count -and $items.Count) { return , ([hashtable[]]$items) }
        if (@($items | Where-Object { $_ -is [string] }).Count -eq $items.Count) { return , ([string[]]$items) }
        return , $items
    }
    return $Value
}

function New-PpdfCreateParameter {
    param([Parameter(Mandatory)]$Desired, [string]$NameParameter = 'Name', [System.Collections.IDictionary]$Extra = @{}, [string[]]$Exclude = @())
    $p = [ordered]@{ $NameParameter = $Desired.Name }
    foreach ($k in $Desired.Properties.Keys) {
        if ($k -in $Exclude) { continue }
        $v = $Desired.Properties[$k]
        if ($null -eq $v -or ((Test-PpdfList $v) -and @($v).Count -eq 0)) { continue }
        $p[$k] = ConvertTo-PpdfCmdletValue $v
    }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    return $p
}

function Get-PpdfPathValue {
    <#
    .SYNOPSIS
    Returns the first non-empty value among candidate (optionally dotted) property paths. Used to read service
    payloads whose field names are not contractually stable.
    #>
    param($InputObject, [string[]]$Path)
    foreach ($candidate in $Path) {
        $cur = $InputObject
        foreach ($seg in $candidate.Split('.')) {
            if ($null -eq $cur) { break }
            if (Test-PpdfList $cur) { $cur = @($cur)[0] }
            $cur = Get-PpdfValue $cur $seg
        }
        if ($null -ne $cur -and -not ($cur -is [string] -and $cur -eq '')) { return $cur }
    }
    return $null
}

function Get-PpdfActivityRecord {
    <#
    .SYNOPSIS
    Reads Activity Explorer records (Export-ActivityExplorerData) for a policy since a point in time, following page cookies.
    #>
    param([string]$PolicyName, [datetime]$Since, [string]$Activity = 'DLPRuleMatch', [int]$MaxPages = 50)
    $end = (Get-Date).ToUniversalTime()
    $start = $Since.ToUniversalTime()
    # Activity Explorer exports are limited to a 30 day window.
    if (($end - $start).TotalDays -gt 30) { $start = $end.AddDays(-30) }
    $records = [System.Collections.Generic.List[object]]::new()
    $cookie = $null
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $p = [ordered]@{
            StartTime    = $start.ToString('MM/dd/yyyy HH:mm:ss', [cultureinfo]::InvariantCulture)
            EndTime      = $end.ToString('MM/dd/yyyy HH:mm:ss', [cultureinfo]::InvariantCulture)
            OutputFormat = 'Json'
            PageSize     = 5000
            Filter1      = @('Activity', $Activity)
            Filter2      = @('PolicyName', $PolicyName)
        }
        if ($cookie) { $p.PageCookie = $cookie }
        $r = Invoke-PpdfCmdlet -Name 'Export-ActivityExplorerData' -Parameters $p
        $data = Get-PpdfValue $r 'ResultData'
        if ($data) {
            $parsed = if ($data -is [string]) { ConvertFrom-Json -InputObject $data -AsHashtable -Depth 32 } else { ConvertTo-PpdfPlainValue $data }
            foreach ($x in @($parsed)) { if ($null -ne $x) { $records.Add($x) } }
        }
        if ((Get-PpdfValue $r 'LastPage' $true) -eq $true) { break }
        $cookie = Get-PpdfValue $r 'WaterMark'
        if (-not $cookie) { break }
    }
    return , $records.ToArray()
}

function Get-PpdfDistributionSuccess {
    <#
    .SYNOPSIS
    True when a compliance policy reports DistributionStatus Success (deployed to all workloads).
    #>
    param([string]$Cmdlet, [string]$Identity)
    $p = Get-PpdfCmdletObject -Name $Cmdlet -Parameters @{ Identity = $Identity; DistributionDetail = $true }
    if (-not $p) { return $false }
    return ([string](Get-PpdfValue $p 'DistributionStatus') -eq 'Success')
}

function Get-PpdfTaggedList {
    <#
    .SYNOPSIS
    Lists objects from a Get-* cmdlet and returns normalized dictionaries for those carrying a ppdf ownership tag.
    #>
    param([string]$Cmdlet, [string]$TagProperty, [scriptblock]$Normalize, [System.Collections.IDictionary]$Parameters = @{})
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @(Invoke-PpdfCmdlet -Name $Cmdlet -Parameters $Parameters)) {
        if ($null -eq $o) { continue }
        $text = [string](Get-PpdfValue $o $TagProperty)
        if ($text -notmatch '\[ppdf:v1') { continue }
        $out.Add((& $Normalize $o))
    }
    return , $out.ToArray()
}

function Get-PpdfSafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]' '
    $s = -join ($Name.ToCharArray() | ForEach-Object { if ($_ -in $invalid) { '-' } else { $_ } })
    return $s.Trim('-').ToLowerInvariant()
}

function New-PpdfExportDocument {
    param([string]$Kind, [string]$Name, [System.Collections.IDictionary]$Spec, [string]$Description)
    $meta = [ordered]@{ name = $Name; adopt = $true }
    if ($Description) { $meta.description = $Description }
    return [ordered]@{ apiVersion = 'ppdf.purview/v1'; kind = $Kind; metadata = $meta; spec = $Spec }
}

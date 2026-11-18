function ConvertTo-PpdfComparableScalar {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    $s = ([string]$Value).Trim()
    if ($s -match '^(?i)(true|false)$') { return $s.ToLowerInvariant() }
    return $s.ToLowerInvariant()
}

function Test-PpdfEmpty {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrEmpty($Value) }
    if (Test-PpdfList $Value) { return (@($Value).Count -eq 0) }
    return $false
}

function Test-PpdfValueMatch {
    <#
    .SYNOPSIS
    Desired-subset comparison. Returns $true when Current satisfies Desired.
    .DESCRIPTION
    - Scalars compare case-insensitively; booleans are normalized ("True" == $true).
    - A desired scalar matches a single-element current array.
    - Scalar arrays compare as sets (order-insensitive).
    - Object arrays require equal counts and every desired element to subset-match a distinct current element.
    - Dictionaries compare only the keys present in Desired.
    - Empty/null desired means current must be empty.
    #>
    param($Desired, $Current)

    if (Test-PpdfEmpty $Desired) { return (Test-PpdfEmpty $Current) }

    if (Test-PpdfDictionary $Desired) {
        if ($null -eq $Current) { return $false }
        foreach ($k in $Desired.Keys) {
            if (-not (Test-PpdfValueMatch -Desired $Desired[$k] -Current (Get-PpdfValue $Current ([string]$k)))) { return $false }
        }
        return $true
    }

    if (Test-PpdfList $Desired) {
        $d = @($Desired)
        $c = if ($null -eq $Current) { @() } elseif (Test-PpdfList $Current) { @($Current) } else { @($Current) }
        if ($d.Count -ne $c.Count) { return $false }
        $isObjectList = @($d | Where-Object { (Test-PpdfDictionary $_) -or (Test-PpdfList $_) }).Count -gt 0
        if (-not $isObjectList) {
            $ds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $cs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($x in $d) { [void]$ds.Add((ConvertTo-PpdfComparableScalar $x)) }
            foreach ($x in $c) {
                $cv = if ((Test-PpdfDictionary $x) -or ($null -ne $x -and $x -isnot [string] -and -not $x.GetType().IsPrimitive -and $x -isnot [datetime])) {
                    (Get-PpdfLocationName $x)[0]
                }
                else { $x }
                [void]$cs.Add((ConvertTo-PpdfComparableScalar $cv))
            }
            return $ds.SetEquals($cs)
        }
        $used = [bool[]]::new($c.Count)
        foreach ($de in $d) {
            $found = $false
            for ($i = 0; $i -lt $c.Count; $i++) {
                if ($used[$i]) { continue }
                if (Test-PpdfValueMatch -Desired $de -Current $c[$i]) { $used[$i] = $true; $found = $true; break }
            }
            if (-not $found) { return $false }
        }
        return $true
    }

    # Desired scalar
    if (Test-PpdfList $Current) {
        $c = @($Current)
        if ($c.Count -ne 1) { return $false }
        $Current = $c[0]
    }
    if (Test-PpdfDictionary $Current) { return $false }
    return ((ConvertTo-PpdfComparableScalar $Desired) -eq (ConvertTo-PpdfComparableScalar $Current))
}

function Compare-PpdfProperty {
    <#
    .SYNOPSIS
    Returns the list of desired property names whose values differ from current.
    #>
    param([System.Collections.IDictionary]$Desired, $Current, [string[]]$Ignore = @())
    $diff = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Desired.Keys) {
        if ($k -in $Ignore) { continue }
        if (-not (Test-PpdfValueMatch -Desired $Desired[$k] -Current (Get-PpdfValue $Current ([string]$k)))) { $diff.Add([string]$k) }
    }
    return , $diff.ToArray()
}

function Get-PpdfProjection {
    <#
    .SYNOPSIS
    Projects Current onto a set of keys (case-insensitive) producing an ordered dictionary.
    #>
    param($Current, [string[]]$Keys)
    $o = [ordered]@{}
    if ($null -eq $Current) { return $o }
    foreach ($k in ($Keys | Select-Object -Unique)) {
        if (Test-PpdfHasKey $Current $k) { $o[$k] = ConvertTo-PpdfPlainValue (Get-PpdfValue $Current $k) }
    }
    return $o
}

function Get-PpdfListDelta {
    <#
    .SYNOPSIS
    Computes Add/Remove sets (case-insensitive) between desired and current scalar lists.
    #>
    param($Desired, $Current)
    $d = @(if ($null -ne $Desired) { $Desired })
    $c = @(Get-PpdfLocationName $Current)
    $add = @($d | Where-Object { $x = $_; -not ($c | Where-Object { [string]::Equals([string]$_, [string]$x, [StringComparison]::OrdinalIgnoreCase) }) })
    $remove = @($c | Where-Object { $x = $_; -not ($d | Where-Object { [string]::Equals([string]$_, [string]$x, [StringComparison]::OrdinalIgnoreCase) }) })
    return @{ Add = $add; Remove = $remove }
}

function Get-PpdfIgnoreList {
    <#
    .SYNOPSIS
    Properties excluded from comparison: the object type's IgnoreCompare plus any per-object Options.IgnoreCompare.
    #>
    param($TypeDef, $Desired)
    return @(@($TypeDef.IgnoreCompare) + @(Get-PpdfValue $Desired.Options 'IgnoreCompare' @()) | Where-Object { $_ })
}

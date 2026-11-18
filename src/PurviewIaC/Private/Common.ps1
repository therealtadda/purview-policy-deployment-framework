function Test-PpdfDictionary {
    param($InputObject)
    return ($InputObject -is [System.Collections.IDictionary])
}

function Test-PpdfList {
    param($InputObject)
    return ($null -ne $InputObject -and $InputObject -isnot [string] -and $InputObject -isnot [System.Collections.IDictionary] -and
        $InputObject -is [System.Collections.IEnumerable])
}

function Get-PpdfValue {
    <#
    .SYNOPSIS
    Case-insensitive lookup on dictionaries and objects. Returns $Default when the key/property is absent.
    #>
    param($InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if (Test-PpdfDictionary $InputObject) {
        foreach ($k in $InputObject.Keys) {
            if ([string]::Equals([string]$k, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                $v = $InputObject[$k]
                if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary]) { return , $v }
                return $v
            }
        }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    $v = $prop.Value
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary]) { return , $v }
    return $v
}

function Test-PpdfHasKey {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $false }
    if (Test-PpdfDictionary $InputObject) {
        foreach ($k in $InputObject.Keys) { if ([string]::Equals([string]$k, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function ConvertTo-PpdfPlainValue {
    <#
    .SYNOPSIS
    Converts cmdlet output (PSObjects, MultiValuedProperty, DateTime, enums) into plain ordered dictionaries/arrays/scalars.
    #>
    param($InputObject, [int]$Depth = 6)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or $InputObject -is [long] -or
        $InputObject -is [double] -or $InputObject -is [decimal]) { return $InputObject }
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [guid] -or $InputObject -is [enum] -or $InputObject -is [timespan]) { return $InputObject.ToString() }
    if ($InputObject -is [byte[]]) { return [Convert]::ToBase64String($InputObject) }
    if ($Depth -le 0) { return $InputObject.ToString() }
    if (Test-PpdfDictionary $InputObject) {
        $o = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $o[[string]$k] = ConvertTo-PpdfPlainValue -InputObject $InputObject[$k] -Depth ($Depth - 1) }
        return $o
    }
    if (Test-PpdfList $InputObject) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $InputObject) { $list.Add((ConvertTo-PpdfPlainValue -InputObject $i -Depth ($Depth - 1))) }
        return , $list.ToArray()
    }
    if ($InputObject.GetType().IsPrimitive) { return $InputObject }
    $props = @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -in 'NoteProperty', 'Property', 'AliasProperty' })
    if ($props.Count -eq 0) { return $InputObject.ToString() }
    $o = [ordered]@{}
    foreach ($p in $props) {
        try { $o[$p.Name] = ConvertTo-PpdfPlainValue -InputObject $p.Value -Depth ($Depth - 1) } catch { $o[$p.Name] = $null }
    }
    return $o
}

function ConvertTo-PpdfObjectDictionary {
    <#
    .SYNOPSIS
    Converts a cmdlet output object into an ordered dictionary of its (non-noise) properties.
    #>
    param($InputObject, [string[]]$Exclude = @())
    if ($null -eq $InputObject) { return $null }
    if (Test-PpdfDictionary $InputObject) { return (ConvertTo-PpdfPlainValue $InputObject) }
    $noise = @('PSComputerName', 'RunspaceId', 'PSShowComputerName', 'ObjectState', 'IsValid', 'OrganizationId', 'ExchangeVersion', 'ObjectCategory', 'ObjectClass', 'OriginatingServer', 'DistinguishedName')
    $o = [ordered]@{}
    foreach ($p in $InputObject.PSObject.Properties) {
        if ($p.MemberType -notin 'NoteProperty', 'Property', 'AliasProperty') { continue }
        if ($p.Name -in $noise -or $p.Name -in $Exclude) { continue }
        try { $o[$p.Name] = ConvertTo-PpdfPlainValue -InputObject $p.Value -Depth 5 } catch { $o[$p.Name] = [string]$p.Value }
    }
    return $o
}

function ConvertTo-PpdfCanonical {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if (Test-PpdfDictionary $InputObject) {
        [string[]]$keys = @($InputObject.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $o = [ordered]@{}
        foreach ($k in $keys) { $o[$k] = ConvertTo-PpdfCanonical -InputObject (Get-PpdfValue $InputObject $k) }
        return $o
    }
    if (Test-PpdfList $InputObject) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($i in $InputObject) { $list.Add((ConvertTo-PpdfCanonical -InputObject $i)) }
        return , $list.ToArray()
    }
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) { return ConvertTo-PpdfCanonical -InputObject (ConvertTo-PpdfPlainValue $InputObject) }
    return $InputObject
}

function ConvertTo-PpdfCanonicalJson {
    param($InputObject)
    $c = ConvertTo-PpdfCanonical -InputObject $InputObject
    return (ConvertTo-Json -InputObject $c -Depth 64 -Compress)
}

function Get-PpdfHash {
    param($InputObject, [switch]$Text)
    $s = if ($Text) { [string]$InputObject } else { ConvertTo-PpdfCanonicalJson -InputObject $InputObject }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Copy-PpdfObject {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 64 -Compress
    $p = @{ AsHashtable = $true; Depth = 64 }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $p.DateKind = 'String' }
    return (ConvertFrom-Json -InputObject $json @p)
}

function Write-PpdfJson {
    param($InputObject, [string]$Path)
    $json = ConvertTo-Json -InputObject $InputObject -Depth 64
    Set-Content -Path $Path -Value $json -Encoding utf8NoBOM
}

function Read-PpdfJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $p = @{ AsHashtable = $true; Depth = 64 }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $p.DateKind = 'String' }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @p)
}

#region Ownership tag
$script:PpdfTagPattern = '\s*\[ppdf:v1(?<body>[^\]]*)\]'

function Format-PpdfTag {
    param([string]$Id, [string]$Sha, [string]$Stage)
    $short = if ($Sha.Length -ge 8) { $Sha.Substring(0, 8) } else { $Sha }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return "[ppdf:v1 id=$Id sha=$short stage=$Stage ts=$ts]"
}

function Split-PpdfTaggedText {
    <#
    .SYNOPSIS
    Splits a Comment/Description value into the human text and the parsed ppdf ownership tag (or $null).
    #>
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @{ Text = ''; Tag = $null } }
    $m = [regex]::Match($Text, $script:PpdfTagPattern)
    if (-not $m.Success) { return @{ Text = $Text.Trim(); Tag = $null } }
    $tag = @{}
    foreach ($pair in ($m.Groups['body'].Value.Trim() -split '\s+')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) { $tag[$kv[0]] = $kv[1] }
    }
    $clean = ([regex]::Replace($Text, $script:PpdfTagPattern, '')).Trim()
    return @{ Text = $clean; Tag = $tag }
}

function Join-PpdfTaggedText {
    param([AllowNull()][string]$Text, [string]$Tag)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Tag }
    return "$($Text.Trim()) $Tag"
}
#endregion

#region Risk tiers
$script:PpdfTiers = @('low', 'standard', 'elevated', 'critical')

function Get-PpdfTierRank {
    param([string]$Tier)
    $i = [array]::IndexOf($script:PpdfTiers, ([string]$Tier).ToLowerInvariant())
    if ($i -lt 0) { return 0 }
    return $i
}

function Get-PpdfMaxTier {
    param([string[]]$Tier)
    $max = 0
    foreach ($t in $Tier) { if ($t) { $max = [Math]::Max($max, (Get-PpdfTierRank $t)) } }
    return $script:PpdfTiers[$max]
}
#endregion

function Resolve-PpdfRelativePath {
    param([string]$BasePath, [string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $baseDir = if (Test-Path -LiteralPath $BasePath -PathType Leaf) { Split-Path -Parent $BasePath } else { $BasePath }
    return [System.IO.Path]::GetFullPath((Join-Path $baseDir $Path))
}

function Get-PpdfLocationName {
    <#
    .SYNOPSIS
    Normalizes location values returned by S&C cmdlets (strings or binding objects) to plain names.
    #>
    param($Value)
    $out = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return , $out.ToArray() }
    $items = if (Test-PpdfList $Value) { $Value } else { @($Value) }
    foreach ($i in $items) {
        if ($null -eq $i) { continue }
        if ($i -is [string]) { if ($i) { $out.Add($i) }; continue }
        $n = $null
        foreach ($p in 'Name', 'DisplayName', 'Identity', 'ImmutableIdentity') {
            $n = Get-PpdfValue $i $p
            if ($n) { break }
        }
        if (-not $n) { $n = [string]$i }
        $out.Add([string]$n)
    }
    return , $out.ToArray()
}

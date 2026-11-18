# Sensitive information type provider: kind SensitiveInfoTypeRulePackage -> SitRulePackage (one custom rule pack XML).
# Simulation strategy "corpus": a rule pack is inert until a policy references it, so the simulate stage deploys it
# and the simulation report runs a labelled test corpus through Test-DataClassification (precision/recall).
# Rule packs cannot carry an ownership tag; identity is the RulePack id GUID declared in the XML.

$script:SitMicrosoftPublisher = 'Microsoft Corporation'

function ConvertFrom-PpdfRulePackByte {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    $enc = [System.Text.Encoding]::UTF8
    if ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -ne 0 -and $Bytes[1] -eq 0))) { $enc = [System.Text.Encoding]::Unicode }
    elseif ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) -or ($Bytes[0] -eq 0 -and $Bytes[1] -ne 0))) { $enc = [System.Text.Encoding]::BigEndianUnicode }
    $reader = [System.IO.StreamReader]::new([System.IO.MemoryStream]::new($Bytes), $enc, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-PpdfRulePackXml {
    <#
    .SYNOPSIS
    Parses rule pack XML safely (no DTDs / external resolution) and returns id, version, publisher, entities and a
    whitespace-normalized content hash.
    #>
    param([Parameter(Mandatory)][string]$Xml)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.IgnoreWhitespace = $true
    $settings.IgnoreComments = $true
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Xml.TrimStart([char]0xFEFF)), $settings)
    try {
        $doc = [System.Xml.XmlDocument]::new()
        $doc.XmlResolver = $null
        $doc.Load($reader)
    }
    finally { $reader.Dispose() }
    $ns = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
    $ns.AddNamespace('m', $doc.DocumentElement.NamespaceURI)
    $pack = $doc.SelectSingleNode('/m:RulePackage/m:RulePack', $ns)
    if (-not $pack) { throw 'RulePackage/RulePack element not found.' }
    $v = $pack.SelectSingleNode('m:Version', $ns)
    $version = if ($v) { '{0}.{1}.{2}.{3}' -f $v.GetAttribute('major'), $v.GetAttribute('minor'), $v.GetAttribute('build'), $v.GetAttribute('revision') } else { $null }
    $publisher = [string]($pack.SelectSingleNode('m:Publisher', $ns).id)
    $details = $pack.SelectSingleNode('m:Details/m:LocalizedDetails', $ns)
    $publisherName = if ($details) { [string]$details.SelectSingleNode('m:PublisherName', $ns).InnerText } else { '' }
    $packName = if ($details) { [string]$details.SelectSingleNode('m:Name', $ns).InnerText } else { '' }
    $names = @{}
    foreach ($res in @($doc.SelectNodes('/m:RulePackage/m:Rules/m:LocalizedStrings/m:Resource', $ns))) {
        $n = $res.SelectSingleNode("m:Name[@default='true']", $ns)
        if (-not $n) { $n = $res.SelectSingleNode('m:Name', $ns) }
        if ($n) { $names[$res.GetAttribute('idRef').ToLowerInvariant()] = $n.InnerText.Trim() }
    }
    $entities = @(foreach ($e in @($doc.SelectNodes('/m:RulePackage/m:Rules/m:Entity', $ns))) {
            $id = $e.GetAttribute('id').ToLowerInvariant()
            [ordered]@{ Id = $id; Name = if ($names.ContainsKey($id)) { $names[$id] } else { $id } }
        })
    return [ordered]@{
        Id            = $pack.GetAttribute('id').ToLowerInvariant()
        Version       = $version
        Publisher     = $publisher
        PublisherName = $publisherName
        Name          = $packName
        Entities      = $entities
        ContentHash   = (Get-PpdfHash -InputObject $doc.DocumentElement.OuterXml -Text).Substring(0, 16)
    }
}

function Get-PpdfRulePackXmlFromObject {
    param($InputObject)
    foreach ($p in 'SerializedClassificationRuleCollection', 'ClassificationRuleCollectionXml') {
        $v = Get-PpdfValue $InputObject $p
        if ($null -eq $v) { continue }
        if ($v -is [byte[]]) { return (ConvertFrom-PpdfRulePackByte $v) }
        if ($v -is [string] -and $v.TrimStart().StartsWith('<')) { return $v }
        if ($v -is [string]) { try { return (ConvertFrom-PpdfRulePackByte ([Convert]::FromBase64String($v))) } catch { return $v } }
    }
    return $null
}

function Get-PpdfRulePackList {
    <#
    .SYNOPSIS
    Returns all rule packages in the tenant with parsed XML metadata.
    #>
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @(Invoke-PpdfCmdlet -Name 'Get-DlpSensitiveInformationTypeRulePackage')) {
        if ($null -eq $o) { continue }
        $xml = Get-PpdfRulePackXmlFromObject $o
        if (-not $xml) { continue }
        try { $info = Read-PpdfRulePackXml -Xml $xml } catch { Write-PpdfLog -Level warn -Message "Unable to parse rule package '$([string]$o.Identity)': $($_.Exception.Message)"; continue }
        $out.Add([ordered]@{ Object = $o; Xml = $xml; Info = $info; ServiceIdentity = [string](Get-PpdfValue $o 'Identity') })
    }
    return , $out.ToArray()
}

function Get-PpdfSitRulePackPath {
    param($Artifact)
    return (Resolve-PpdfRelativePath -BasePath $Artifact.Path -Path ([string]$Artifact.Doc.spec.rulePackFile))
}

Register-PpdfObjectType -Name 'SitRulePackage' -Workload 'classifier' -Service 'scc' `
    -KnownProperties @('Version', 'ContentHash') `
    -Get {
    param($Desired, $Context)
    $match = @(Get-PpdfRulePackList | Where-Object { $_.Info.Id -eq ([string]$Desired.Name).ToLowerInvariant() })
    if (-not $match.Count) { return $null }
    $m = $match[0]
    return [ordered]@{ Name = $m.Info.Id; Version = $m.Info.Version; ContentHash = $m.Info.ContentHash; ServiceIdentity = $m.ServiceIdentity; Entities = @($m.Info.Entities | ForEach-Object { $_.Name }) }
} -Create {
    param($Desired, $Context)
    $bytes = [Convert]::FromBase64String([string]$Desired.Options.FileDataBase64)
    Invoke-PpdfCmdlet -Name 'New-DlpSensitiveInformationTypeRulePackage' -Parameters @{ FileData = $bytes }
} -Update {
    param($Desired, $Current, $DiffKeys, $Context)
    $bytes = [Convert]::FromBase64String([string]$Desired.Options.FileDataBase64)
    $identity = [string](Get-PpdfValue $Current 'ServiceIdentity' $Desired.Name)
    $p = @{ FileData = $bytes; Confirm = $false }
    if ((Test-PpdfCmdletParameter -Name 'Set-DlpSensitiveInformationTypeRulePackage' -Parameter 'Identity') -and $identity) { $p.Identity = $identity }
    Invoke-PpdfCmdlet -Name 'Set-DlpSensitiveInformationTypeRulePackage' -Parameters $p
} -Remove {
    param($Desired, $Current, $Context)
    $identity = [string](Get-PpdfValue $Current 'ServiceIdentity' $Desired.Name)
    Invoke-PpdfCmdlet -Name 'Remove-DlpSensitiveInformationTypeRulePackage' -Parameters @{ Identity = $identity; Confirm = $false }
}

Register-PpdfKind -Name 'SensitiveInfoTypeRulePackage' -Workload 'classifier' -IdentityRole 'classifier' -SimulationStrategy 'corpus' -RequiresSimulationEvidence $true `
    -Description 'Custom sensitive information types (rule package XML), validated against a labelled test corpus.' `
    -DefaultThresholds @{ minPrecision = 0.9; minRecall = 0.9; maxFalsePositives = 0 } `
    -Expand {
    param($Artifact, $Context, $Stage, $Shadow)
    $spec = $Artifact.Doc.spec
    $path = Get-PpdfSitRulePackPath $Artifact
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $info = Read-PpdfRulePackXml -Xml (ConvertFrom-PpdfRulePackByte $bytes)
    $opts = [ordered]@{ FileDataBase64 = [Convert]::ToBase64String($bytes); RulePackFile = [string]$spec.rulePackFile }
    if ((Get-PpdfValue $spec 'compareContent' $true) -eq $false) { $opts.IgnoreCompare = @('ContentHash') }
    New-PpdfDesiredObject -Type 'SitRulePackage' -Name $info.Id -Order 5 -Primary `
        -Properties ([ordered]@{ Version = $info.Version; ContentHash = $info.ContentHash }) -Options $opts
} -Validate {
    param($Artifact, $EnvSpec)
    $spec = $Artifact.Doc.spec
    $path = Get-PpdfSitRulePackPath $Artifact
    if (-not (Test-Path -LiteralPath $path)) { "rulePackFile not found: $($spec.rulePackFile)"; return }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt 150KB) { 'Rule package exceeds the 150 KB service limit.' }
    try { $info = Read-PpdfRulePackXml -Xml (ConvertFrom-PpdfRulePackByte $bytes) } catch { "rulePackFile is not a valid rule package: $($_.Exception.Message)"; return }
    if ($info.Id -notmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') { 'RulePack id must be a GUID.' }
    if (-not $info.Version) { 'RulePack must declare a Version element.' }
    if (-not @($info.Entities).Count) { 'Rule package declares no Entity elements.' }
    if ($info.Id -eq '00000000-0000-0000-0000-000000000000') { 'Replace the placeholder RulePack id with a unique GUID.' }
    $corpus = Get-PpdfValue $spec 'testCorpusFile'
    if ($corpus) {
        $cp = Resolve-PpdfRelativePath -BasePath $Artifact.Path -Path ([string]$corpus)
        if (-not (Test-Path -LiteralPath $cp)) { "testCorpusFile not found: $corpus" }
        else {
            try {
                $manifest = Read-PpdfDocument -Path $cp
                $known = @($info.Entities | ForEach-Object { $_.Name })
                foreach ($c in @(Get-PpdfValue $manifest 'cases' @())) {
                    foreach ($x in @(Get-PpdfValue $c 'expect' @())) { if ($x -notin $known) { "Corpus case '$($c.name)' expects '$x', which is not an entity in this rule package." } }
                    if (-not (Get-PpdfValue $c 'text') -and -not (Get-PpdfValue $c 'file')) { "Corpus case '$($c.name)' needs text or file." }
                }
            }
            catch { "testCorpusFile could not be read: $($_.Exception.Message)" }
        }
    }
    else { 'testCorpusFile is required: simulation evidence for SITs comes from the test corpus.' }
} -Assess {
    param($Action, $Artifact, $Context)
    if ($Action.op -eq 'update') {
        if ('ContentHash' -in $Action.diffKeys -and 'Version' -notin $Action.diffKeys) {
            @{ Tier = 'standard'; Reason = 'Rule package content changed without a Version bump; the service may reject or cache it. Increment the RulePack Version.'; Block = $true }
        }
        if ('Version' -in $Action.diffKeys -and $Action.expected -and $Action.expected.Version) {
            try { if ([version]$Action.desired.Version -lt [version]$Action.expected.Version) { @{ Tier = 'critical'; Reason = "Rule package Version goes backwards ($($Action.expected.Version) -> $($Action.desired.Version))."; Block = $true } } } catch { Write-Verbose 'Non-numeric rule pack version.' }
        }
        @{ Tier = 'elevated'; Reason = 'Changes detection logic used by any policy that references these sensitive information types.' }
    }
    if ($Action.op -eq 'delete') { @{ Tier = 'critical'; Reason = 'Deleting a rule package fails or breaks policies that still reference its SITs.' } }
} -SimulationResult {
    param($Artifact, $Context, $Target)
    $spec = $Artifact.Doc.spec
    $info = Read-PpdfRulePackXml -Xml (ConvertFrom-PpdfRulePackByte ([System.IO.File]::ReadAllBytes((Get-PpdfSitRulePackPath $Artifact))))
    $entityNames = @($info.Entities | ForEach-Object { $_.Name })
    $manifestPath = Resolve-PpdfRelativePath -BasePath $Artifact.Path -Path ([string]$spec.testCorpusFile)
    $manifest = Read-PpdfDocument -Path $manifestPath
    $tp = 0; $fp = 0; $fn = 0
    $cases = [System.Collections.Generic.List[object]]::new()
    $scopeByName = Test-PpdfCmdletParameter -Name 'Test-DataClassification' -Parameter 'ClassificationNames'
    foreach ($c in @(Get-PpdfValue $manifest 'cases' @())) {
        $text = Get-PpdfValue $c 'text'
        if (-not $text) { $text = Get-Content -LiteralPath (Resolve-PpdfRelativePath -BasePath $manifestPath -Path ([string]$c.file)) -Raw }
        $tdc = @{ TextToClassify = [string]$text }
        if ($scopeByName) { $tdc.ClassificationNames = [string[]]$entityNames }
        $r = Invoke-PpdfCmdlet -Name 'Test-DataClassification' -Parameters $tdc
        $detected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($res in @(Get-PpdfValue $r 'ClassificationResults' @())) {
            $n = [string](Get-PpdfPathValue $res @('ClassificationName', 'Name', 'SensitiveInformationTypeName'))
            $count = Get-PpdfPathValue $res @('Count', 'MatchCount')
            if ($n -and $n -in $entityNames -and ($null -eq $count -or [int]$count -gt 0)) { [void]$detected.Add($n) }
        }
        $expect = @(Get-PpdfValue $c 'expect' @())
        $caseTp = @($expect | Where-Object { $detected.Contains($_) })
        $caseFn = @($expect | Where-Object { -not $detected.Contains($_) })
        $caseFp = @($detected | Where-Object { $_ -notin $expect })
        $tp += $caseTp.Count; $fn += $caseFn.Count; $fp += $caseFp.Count
        $cases.Add([ordered]@{ name = [string]$c.name; expected = $expect; detected = @($detected); falsePositives = $caseFp; falseNegatives = $caseFn; pass = ($caseFp.Count + $caseFn.Count -eq 0) })
    }
    return [ordered]@{
        cases          = $cases.Count
        truePositives  = $tp
        falsePositives = $fp
        falseNegatives = $fn
        precision      = if ($tp + $fp) { [Math]::Round($tp / ($tp + $fp), 4) } else { 1.0 }
        recall         = if ($tp + $fn) { [Math]::Round($tp / ($tp + $fn), 4) } else { 1.0 }
        rulePackVersion = $info.Version
        caseResults    = $cases.ToArray()
    }
} -Export {
    param($Context)
    foreach ($p in (Get-PpdfRulePackList)) {
        if ($p.Info.PublisherName -eq $script:SitMicrosoftPublisher) { continue }
        $name = if ($p.Info.Name) { ($p.Info.Name -replace '[\[\]<>%&]', '').Trim() } else { $p.Info.Id }
        if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
        $safe = Get-PpdfSafeFileName $name
        $spec = [ordered]@{ rulePackFile = "./$safe.xml"; testCorpusFile = "./$safe.corpus.yml" }
        $corpus = "# Labelled test corpus for $name. Add positive and negative cases before simulating.`ncases:`n" +
        (($p.Info.Entities | ForEach-Object { "  - name: positive-$((Get-PpdfSafeFileName $_.Name))`n    text: `"REPLACE with a sample that should match`"`n    expect: [`"$($_.Name)`"]" }) -join "`n") +
        "`n  - name: negative-baseline`n    text: `"Ordinary text that should not match anything.`"`n    expect: []`n"
        @{
            Name  = $name
            Doc   = (New-PpdfExportDocument -Kind 'SensitiveInfoTypeRulePackage' -Name $name -Spec $spec -Description "Exported rule pack $($p.Info.Id) version $($p.Info.Version).")
            Files = @{ "$safe.xml" = [System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($p.Xml); "$safe.corpus.yml" = $corpus }
        }
    }
}

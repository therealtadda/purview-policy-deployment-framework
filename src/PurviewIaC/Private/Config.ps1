function ConvertFrom-PpdfYamlNode {
    param($Node)
    if ($Node -is [YamlDotNet.RepresentationModel.YamlMappingNode]) {
        $o = [ordered]@{}
        foreach ($kv in $Node.Children.GetEnumerator()) { $o[[string]$kv.Key.Value] = ConvertFrom-PpdfYamlNode $kv.Value }
        return $o
    }
    if ($Node -is [YamlDotNet.RepresentationModel.YamlSequenceNode]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $Node.Children) { $list.Add((ConvertFrom-PpdfYamlNode $c)) }
        return , $list.ToArray()
    }
    $v = $Node.Value
    if ($Node.Style -ne [YamlDotNet.Core.ScalarStyle]::Plain) { return $v }
    if ($null -eq $v -or $v -in @('', '~', 'null', 'Null', 'NULL')) { return $null }
    if ($v -cin @('true', 'True', 'TRUE')) { return $true }
    if ($v -cin @('false', 'False', 'FALSE')) { return $false }
    if ($v -match '^[-+]?[0-9]+$') { $l = 0L; if ([long]::TryParse($v, [ref]$l)) { if ($l -ge [int]::MinValue -and $l -le [int]::MaxValue) { return [int]$l }; return $l } }
    if ($v -match '^[-+]?([0-9]*\.[0-9]+|[0-9]+\.[0-9]*)([eE][-+]?[0-9]+)?$') { return [double]::Parse($v, [cultureinfo]::InvariantCulture) }
    return $v
}

function ConvertFrom-PpdfYaml {
    <#
    .SYNOPSIS
    Parses YAML using powershell-yaml when available, otherwise YamlDotNet from PPDF_YAMLDOTNET_PATH.
    #>
    param([Parameter(Mandatory)][string]$Yaml)
    if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        $r = ConvertFrom-Yaml -Yaml $Yaml -Ordered
        # Round-trip through JSON so lists/maps have consistent types regardless of parser.
        return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $r -Depth 64) -AsHashtable -Depth 64)
    }
    if (-not ('YamlDotNet.RepresentationModel.YamlStream' -as [type])) {
        if ($env:PPDF_YAMLDOTNET_PATH -and (Test-Path $env:PPDF_YAMLDOTNET_PATH)) { Add-Type -Path $env:PPDF_YAMLDOTNET_PATH }
        else { throw "No YAML parser available. Install-Module powershell-yaml, set PPDF_YAMLDOTNET_PATH to a YamlDotNet.dll, or use .json config files." }
    }
    $stream = [YamlDotNet.RepresentationModel.YamlStream]::new()
    $stream.Load([System.IO.StringReader]::new($Yaml))
    if ($stream.Documents.Count -eq 0) { return $null }
    $r = ConvertFrom-PpdfYamlNode $stream.Documents[0].RootNode
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $r -Depth 64) -AsHashtable -Depth 64)
}

function ConvertTo-PpdfYaml {
    param($InputObject)
    if (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue) { return (ConvertTo-Yaml -Data $InputObject) }
    return $null
}

function Read-PpdfDocument {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($Path -match '\.json$') { return (ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 64) }
    return (ConvertFrom-PpdfYaml -Yaml $raw)
}

function Resolve-PpdfVariable {
    <#
    .SYNOPSIS
    Substitutes ${name} (environment variables map) and ${env:NAME} (process environment) placeholders.
    A string consisting solely of a placeholder is replaced by the raw value (so arrays/maps can be injected).
    #>
    param($InputObject, [System.Collections.IDictionary]$Variables = @{}, [string]$Path = '')
    if ($null -eq $InputObject) { return $null }
    if (Test-PpdfDictionary $InputObject) {
        $o = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $o[$k] = Resolve-PpdfVariable -InputObject $InputObject[$k] -Variables $Variables -Path "$Path.$k" }
        return $o
    }
    if (Test-PpdfList $InputObject) {
        $list = [System.Collections.Generic.List[object]]::new()
        $i = 0
        foreach ($x in $InputObject) { $list.Add((Resolve-PpdfVariable -InputObject $x -Variables $Variables -Path "$Path[$i]")); $i++ }
        return , $list.ToArray()
    }
    if ($InputObject -isnot [string]) { return $InputObject }
    $lookup = {
        param([string]$expr)
        if ($expr -like 'env:*') {
            $n = $expr.Substring(4)
            $v = [Environment]::GetEnvironmentVariable($n)
            if ($null -eq $v) { throw "Environment variable '$n' referenced at '$Path' is not set." }
            return $v
        }
        if (-not (Test-PpdfHasKey $Variables $expr)) { throw "Variable '`${$expr}' referenced at '$Path' is not defined in the environment's spec.variables." }
        return (Get-PpdfValue $Variables $expr)
    }
    $whole = [regex]::Match($InputObject, '^\$\{(?<n>[A-Za-z0-9_.:-]+)\}$')
    if ($whole.Success) { return (& $lookup $whole.Groups['n'].Value) }
    if ($InputObject -notmatch '\$\{') { return $InputObject }
    return [regex]::Replace($InputObject, '\$\{(?<n>[A-Za-z0-9_.:-]+)\}', { param($m) [string](& $lookup $m.Groups['n'].Value) })
}

function Get-PpdfSchemaRoot {
    if ($env:PPDF_SCHEMA_PATH -and (Test-Path $env:PPDF_SCHEMA_PATH)) { return (Resolve-Path $env:PPDF_SCHEMA_PATH).Path }
    $candidate = Join-Path $script:ModuleRoot '..\..\schemas'
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    $candidate = Join-Path $script:ModuleRoot 'schemas'
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    throw 'Schema directory not found. Set PPDF_SCHEMA_PATH.'
}

function Test-PpdfSchema {
    <#
    .SYNOPSIS
    Validates an object against a JSON schema file. Returns an array of error strings (empty when valid).
    #>
    param($InputObject, [string]$SchemaFile)
    $json = ConvertTo-Json -InputObject $InputObject -Depth 64
    $errs = $null
    $ok = Test-Json -Json $json -SchemaFile $SchemaFile -ErrorAction SilentlyContinue -ErrorVariable errs
    if ($ok) { return @() }
    $messages = @(foreach ($e in $errs) {
            $m = $e.Exception.Message
            if ($e.ErrorDetails -and $e.ErrorDetails.Message) { $m = $e.ErrorDetails.Message }
            $m
        })
    if ($messages.Count -eq 0) { $messages = @('Schema validation failed.') }
    return $messages
}

function Get-PpdfConfigRoot {
    param([string]$ConfigRoot)
    if ($ConfigRoot) { return (Resolve-Path $ConfigRoot).Path }
    if ($env:PPDF_CONFIG_ROOT) { return (Resolve-Path $env:PPDF_CONFIG_ROOT).Path }
    return (Resolve-Path (Join-Path (Get-Location) 'config')).Path
}

function Get-PpdfArtifactId {
    param([string]$Kind, [string]$Name)
    return "$Kind/$Name"
}

function Get-PpdfReferencedFileHash {
    <#
    .SYNOPSIS
    Finds spec keys ending in 'File' and hashes the referenced file contents so artifact SHAs change when they change.
    #>
    param($Spec, [string]$ArtifactPath)
    $result = [ordered]@{}
    $walk = $null
    $walk = {
        param($node, $prefix)
        if (Test-PpdfDictionary $node) {
            foreach ($k in $node.Keys) {
                $v = $node[$k]
                if ($k -match 'File$' -and $v -is [string]) {
                    $p = Resolve-PpdfRelativePath -BasePath $ArtifactPath -Path $v
                    $result["$prefix$k"] = if (Test-Path -LiteralPath $p) { ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($p)))).ToLowerInvariant() } else { 'missing' }
                }
                else { & $walk $v "$prefix$k." }
            }
        }
        elseif (Test-PpdfList $node) { foreach ($x in $node) { & $walk $x $prefix } }
    }
    & $walk $Spec ''
    return $result
}

function Get-PpdfContext {
    <#
    .SYNOPSIS
    Loads the environment and all applicable artifacts, performing schema and semantic validation.
    #>
    param(
        [string]$ConfigRoot,
        [Parameter(Mandatory)][string]$Environment,
        [string[]]$Artifact,
        [string[]]$Workload
    )
    $root = Get-PpdfConfigRoot -ConfigRoot $ConfigRoot
    $schemaRoot = Get-PpdfSchemaRoot
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $envFile = @(Get-ChildItem -Path (Join-Path $root 'environments') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq $Environment -and $_.Extension -in '.yml', '.yaml', '.json' })
    if ($envFile.Count -eq 0) { throw "Environment '$Environment' not found under $root/environments." }
    $envDoc = Read-PpdfDocument -Path $envFile[0].FullName
    foreach ($e in (Test-PpdfSchema -InputObject $envDoc -SchemaFile (Join-Path $schemaRoot 'environment.schema.json'))) { $errors.Add("$($envFile[0].Name): $e") }
    $envSpec = Get-PpdfValue $envDoc 'spec' @{}
    $variables = Get-PpdfValue $envSpec 'variables' @{}
    if ($null -eq $variables) { $variables = @{} }
    $envName = [string](Get-PpdfValue (Get-PpdfValue $envDoc 'metadata' @{}) 'name' $Environment)
    if ($envName -ne $Environment) { $errors.Add("$($envFile[0].Name): metadata.name '$envName' does not match file name '$Environment'.") }

    $selectedWorkloads = @(Get-PpdfValue $envSpec 'workloads' @())
    if ($selectedWorkloads.Count -eq 0) { $selectedWorkloads = @($script:Kinds.Values | ForEach-Object { $_.Workload } | Select-Object -Unique) }
    if ($Workload) { $selectedWorkloads = @($selectedWorkloads | Where-Object { $_ -in $Workload }) }

    $artifacts = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $files = @(Get-ChildItem -Path (Join-Path $root 'artifacts') -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.yml', '.yaml', '.json' } | Sort-Object FullName)
    foreach ($f in $files) {
        $rel = [System.IO.Path]::GetRelativePath($root, $f.FullName)
        try { $doc = Read-PpdfDocument -Path $f.FullName }
        catch { $errors.Add("${rel}: unable to parse: $($_.Exception.Message)"); continue }
        if (-not (Test-PpdfDictionary $doc)) { $errors.Add("${rel}: document is not a mapping."); continue }
        if ((Get-PpdfValue $doc 'apiVersion') -ne 'ppdf.purview/v1') { continue }

        $envelopeErrors = @(Test-PpdfSchema -InputObject $doc -SchemaFile (Join-Path $schemaRoot 'artifact.schema.json'))
        if ($envelopeErrors.Count) { foreach ($e in $envelopeErrors) { $errors.Add("${rel}: $e") }; continue }

        $kindName = [string]$doc.kind
        $meta = $doc.metadata
        $name = [string]$meta.name
        $envFilter = @(Get-PpdfValue $meta 'environments' @())
        if ($envFilter.Count -and $Environment -notin $envFilter) { continue }
        if (-not $script:Kinds.ContainsKey($kindName)) { $errors.Add("${rel}: unknown kind '$kindName'. Known kinds: $(($script:Kinds.Keys | Sort-Object) -join ', ')."); continue }
        $kind = $script:Kinds[$kindName]
        $id = Get-PpdfArtifactId -Kind $kindName -Name $name
        if ($seen.ContainsKey($id)) { $errors.Add("${rel}: duplicate artifact '$id' (also in $($seen[$id]))."); continue }
        $seen[$id] = $rel
        # Environment-specific checks (variables, guardrails) only apply to workloads this environment manages.
        if ($kind.Workload -notin $selectedWorkloads) { continue }

        try { $resolved = Resolve-PpdfVariable -InputObject $doc -Variables $variables -Path $rel }
        catch { $errors.Add("${rel}: $($_.Exception.Message)"); continue }

        $kindSchema = Join-Path $schemaRoot "kinds/$kindName.schema.json"
        if (Test-Path $kindSchema) {
            $body = [ordered]@{ spec = (Get-PpdfValue $resolved 'spec' @{}) }
            if (Test-PpdfHasKey $resolved 'simulation') { $body.simulation = $resolved.simulation }
            foreach ($e in (Test-PpdfSchema -InputObject $body -SchemaFile $kindSchema)) { $errors.Add("${rel}: $e") }
        }

        $fileHashes = Get-PpdfReferencedFileHash -Spec (Get-PpdfValue $resolved 'spec' @{}) -ArtifactPath $f.FullName
        $sha = Get-PpdfHash -InputObject ([ordered]@{ doc = $resolved; files = $fileHashes })
        $a = [ordered]@{
            Id           = $id
            Kind         = $kindName
            Name         = $name
            Path         = $f.FullName
            RelativePath = $rel
            Doc          = $resolved
            Sha          = $sha
            Workload     = $kind.Workload
            IdentityRole = $kind.IdentityRole
        }
        if ($kind.Validate) {
            try { foreach ($e in @(& $kind.Validate $a $envSpec)) { if ($e) { $errors.Add("${rel}: $e") } } }
            catch { $errors.Add("${rel}: validation error: $($_.Exception.Message)") }
        }
        if ($Artifact -and ($name -notin $Artifact) -and ($id -notin $Artifact)) { continue }
        $artifacts.Add($a)
    }

    return [ordered]@{
        ConfigRoot  = $root
        EnvName     = $Environment
        EnvDoc      = $envDoc
        Env         = $envSpec
        Workloads   = $selectedWorkloads
        Artifacts   = $artifacts
        Filtered    = [bool]$Artifact
        Errors      = $errors
        Warnings    = $warnings
        ConfigHash  = (Get-PpdfHash -InputObject ([ordered]@{ env = $envDoc; artifacts = @($artifacts | ForEach-Object { "$($_.Id)=$($_.Sha)" }) }))
    }
}

function Get-PpdfLocationOverride {
    <#
    .SYNOPSIS
    Returns the effective location overrides for an artifact: simulation.scope (simulate stage) > ring overrides.
    #>
    param($Artifact, $Context, [string]$Stage)
    $o = [ordered]@{}
    $meta = $Artifact.Doc.metadata
    $ring = Get-PpdfValue $Context.Env 'ring'
    if ($ring -and (Get-PpdfValue $meta 'ringOverrides' $true) -ne $false) {
        $ro = Get-PpdfValue $ring 'locationOverrides'
        if ($ro) { foreach ($k in $ro.Keys) { $o[$k] = $ro[$k] } }
    }
    if ($Stage -eq 'simulate') {
        $scope = Get-PpdfValue (Get-PpdfValue $Artifact.Doc 'simulation') 'scope'
        if ($scope) { foreach ($k in $scope.Keys) { $o[$k] = $scope[$k] } }
    }
    return $o
}

function Set-PpdfLocationOverride {
    <#
    .SYNOPSIS
    Applies overrides only to location keys already present in the policy (never enables new workloads).
    #>
    param([System.Collections.IDictionary]$Properties, [System.Collections.IDictionary]$Override)
    foreach ($k in $Override.Keys) {
        foreach ($pk in @($Properties.Keys)) {
            if ([string]::Equals($pk, $k, [StringComparison]::OrdinalIgnoreCase)) { $Properties[$pk] = $Override[$k] }
        }
    }
}

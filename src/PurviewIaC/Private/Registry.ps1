function Register-PpdfKind {
    <#
    .SYNOPSIS
    Registers an artifact kind (the unit authors write in YAML) with the engine.
    .PARAMETER SimulationStrategy
    mode   - deployed in a non-enforcing mode first and measured (DLP, retention policies)
    corpus - deployed (harmless until referenced) and validated against a labelled test corpus (SITs)
    whatif - not deployable in simulation; plan/what-if only, applied at enforce stage (RBAC)
    none   - no simulation equivalent; inert until referenced (retention labels)
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Workload,
        [Parameter(Mandatory)][string]$IdentityRole,
        [Parameter(Mandatory)][scriptblock]$Expand,
        [scriptblock]$Validate,
        [scriptblock]$Assess,
        [scriptblock]$SimulationResult,
        [scriptblock]$Export,
        [ValidateSet('mode', 'corpus', 'whatif', 'none')][string]$SimulationStrategy = 'none',
        [bool]$RequiresSimulationEvidence = $false,
        [bool]$SupportsShadow = $false,
        [hashtable]$DefaultThresholds = @{},
        [string]$Description
    )
    $script:Kinds[$Name] = [ordered]@{
        Name = $Name; Workload = $Workload; IdentityRole = $IdentityRole; Expand = $Expand; Validate = $Validate; Assess = $Assess
        SimulationResult = $SimulationResult; Export = $Export; SimulationStrategy = $SimulationStrategy
        RequiresSimulationEvidence = $RequiresSimulationEvidence; SupportsShadow = $SupportsShadow
        DefaultThresholds = $DefaultThresholds; Description = $Description
    }
}

function Register-PpdfObjectType {
    <#
    .SYNOPSIS
    Registers a tenant object type (what a kind expands to) and its CRUD adapters.
    All adapters receive and return plain dictionaries. Get/ListManaged must return normalized current state.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Workload,
        [string]$TagProperty,
        [ValidateSet('scc', 'graph')][string]$Service = 'scc',
        [Parameter(Mandatory)][scriptblock]$Get,
        [scriptblock]$ListManaged,
        [Parameter(Mandatory)][scriptblock]$Create,
        [Parameter(Mandatory)][scriptblock]$Update,
        [Parameter(Mandatory)][scriptblock]$Remove,
        [string[]]$KnownProperties = @(),
        [string[]]$IgnoreCompare = @()
    )
    $script:ObjectTypes[$Name] = [ordered]@{
        Name = $Name; Workload = $Workload; TagProperty = $TagProperty; Service = $Service; Get = $Get; ListManaged = $ListManaged
        Create = $Create; Update = $Update; Remove = $Remove; KnownProperties = $KnownProperties; IgnoreCompare = $IgnoreCompare
    }
}

function Get-PpdfObjectType {
    param([string]$Name)
    if (-not $script:ObjectTypes.ContainsKey($Name)) { throw "Unknown object type '$Name'." }
    return $script:ObjectTypes[$Name]
}

function New-PpdfDesiredObject {
    <#
    .SYNOPSIS
    Helper for providers to emit a desired object from Expand.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [int]$Order = 100,
        [string]$Parent,
        [System.Collections.IDictionary]$Properties = [ordered]@{},
        [System.Collections.IDictionary]$Options = [ordered]@{},
        [switch]$Primary
    )
    return [ordered]@{ Type = $Type; Name = $Name; Order = $Order; Parent = $Parent; Properties = $Properties; Options = $Options; Primary = [bool]$Primary }
}

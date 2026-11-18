function Invoke-PpdfCmdlet {
    <#
    .SYNOPSIS
    Single choke point for all Security & Compliance cmdlet calls (mockable, throttling-aware, logged).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Collections.IDictionary]$Parameters = @{},
        [int]$MaxRetries = 4
    )
    $p = @{}
    foreach ($k in $Parameters.Keys) { $p[[string]$k] = $Parameters[$k] }
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Write-PpdfLog -Level debug -Message "cmdlet $Name" -Data @{ parameters = @($p.Keys) }
            return (& $Name @p -ErrorAction Stop)
        }
        catch {
            $msg = $_.Exception.Message
            if ($attempt -le $MaxRetries -and $msg -match '(?i)throttl|too many requests|server busy|429|try again later|timed out') {
                $delay = [Math]::Min(60, [Math]::Pow(2, $attempt) * 2)
                Write-PpdfLog -Level warn -Message "$Name throttled/transient failure (attempt $attempt). Retrying in $delay s."
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

function Test-PpdfNotFoundError {
    param($ErrorRecord)
    $m = [string]$ErrorRecord.Exception.Message
    return ($m -match "(?i)couldn't be found|could not be found|not found|doesn't exist|does not exist|ManagementObjectNotFound|ErrorManagementObjectNotFound")
}

function Get-PpdfCmdletObject {
    <#
    .SYNOPSIS
    Calls a Get-* cmdlet and returns $null when the object does not exist.
    #>
    param([string]$Name, [System.Collections.IDictionary]$Parameters)
    try { return (Invoke-PpdfCmdlet -Name $Name -Parameters $Parameters) }
    catch {
        if (Test-PpdfNotFoundError $_) { return $null }
        throw
    }
}

function Test-PpdfCmdletParameter {
    <#
    .SYNOPSIS
    Capability probe: does the connected session expose cmdlet X with parameter Y?
    #>
    param([string]$Name, [string]$Parameter)
    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    if (-not $Parameter) { return $true }
    return $cmd.Parameters.ContainsKey($Parameter)
}

function Invoke-PpdfGraph {
    <#
    .SYNOPSIS
    Single choke point for Microsoft Graph calls (mockable).
    #>
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'HashTable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = (ConvertTo-Json -InputObject $Body -Depth 20); $p.ContentType = 'application/json' }
    Write-PpdfLog -Level debug -Message "graph $Method $Uri"
    return (Invoke-MgGraphRequest @p)
}

function Get-PpdfGraphCollection {
    param([string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $r = Invoke-PpdfGraph -Method GET -Uri $next
        foreach ($v in @(Get-PpdfValue $r 'value' @())) { $items.Add($v) }
        $next = Get-PpdfValue $r '@odata.nextLink'
    }
    return , $items.ToArray()
}

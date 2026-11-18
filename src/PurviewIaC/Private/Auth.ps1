function Get-PpdfCloudEndpoint {
    param([string]$Cloud = 'Commercial')
    switch ($Cloud) {
        'GCCHigh' {
            return @{ Login = 'https://login.microsoftonline.us'; SccUri = 'https://ps.compliance.protection.office365.us/powershell-liveid/'; SccAuthority = 'https://login.microsoftonline.us/common'; Graph = 'https://graph.microsoft.us'; GraphEnvironment = 'USGov'; SccScope = 'https://ps.compliance.protection.office365.us/.default' }
        }
        'DoD' {
            return @{ Login = 'https://login.microsoftonline.us'; SccUri = 'https://l5.ps.compliance.protection.office365.us/powershell-liveid/'; SccAuthority = 'https://login.microsoftonline.us/common'; Graph = 'https://dod-graph.microsoft.us'; GraphEnvironment = 'USGovDoD'; SccScope = 'https://l5.ps.compliance.protection.office365.us/.default' }
        }
        default {
            # Commercial and GCC (moderate) share the commercial endpoints.
            return @{ Login = 'https://login.microsoftonline.com'; SccUri = $null; SccAuthority = $null; Graph = 'https://graph.microsoft.com'; GraphEnvironment = 'Global'; SccScope = 'https://ps.compliance.protection.outlook.com/.default' }
        }
    }
}

function Get-PpdfFederatedToken {
    <#
    .SYNOPSIS
    Obtains the orchestrator's OIDC token (the "assertion") for workload identity federation.
    #>
    param([string]$AdoServiceConnectionId)
    if ($env:PPDF_FEDERATED_TOKEN) { return $env:PPDF_FEDERATED_TOKEN }
    if ($env:ACTIONS_ID_TOKEN_REQUEST_URL -and $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
        $uri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api://AzureADTokenExchange"
        $r = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }
        return $r.value
    }
    if ($env:idToken) { return $env:idToken } # AzureCLI@2 with addSpnToEnvironment: true
    if ($env:SYSTEM_OIDCREQUESTURI -and $env:SYSTEM_ACCESSTOKEN -and $AdoServiceConnectionId) {
        $uri = "$($env:SYSTEM_OIDCREQUESTURI)?api-version=7.1&serviceConnectionId=$AdoServiceConnectionId"
        $r = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" } -ContentType 'application/json'
        return $r.oidcToken
    }
    if ($env:TFC_WORKLOAD_IDENTITY_TOKEN) { return $env:TFC_WORKLOAD_IDENTITY_TOKEN }
    if ($env:AZURE_FEDERATED_TOKEN_FILE -and (Test-Path $env:AZURE_FEDERATED_TOKEN_FILE)) { return (Get-Content $env:AZURE_FEDERATED_TOKEN_FILE -Raw).Trim() }
    throw 'No federated token source found (GitHub OIDC, Azure DevOps OIDC, TFC workload identity, AZURE_FEDERATED_TOKEN_FILE or PPDF_FEDERATED_TOKEN).'
}

function Get-PpdfManagedIdentityAssertion {
    <#
    .SYNOPSIS
    Gets a managed identity token for api://AzureADTokenExchange, used as a FIC assertion for the app registration.
    #>
    param([string]$ManagedIdentityClientId)
    $resource = 'api://AzureADTokenExchange'
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $uri = "$($env:IDENTITY_ENDPOINT)?api-version=2019-08-01&resource=$resource"
        if ($ManagedIdentityClientId) { $uri += "&client_id=$ManagedIdentityClientId" }
        return (Invoke-RestMethod -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }).access_token
    }
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"
    if ($ManagedIdentityClientId) { $uri += "&client_id=$ManagedIdentityClientId" }
    return (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' }).access_token
}

function Get-PpdfAccessToken {
    <#
    .SYNOPSIS
    Exchanges a federated assertion for an Entra access token (client_credentials with jwt-bearer client assertion).
    #>
    param([string]$TenantId, [string]$ClientId, [string]$Assertion, [string]$Scope, [string]$LoginEndpoint)
    $body = @{
        client_id             = $ClientId
        scope                 = $Scope
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $Assertion
    }
    $r = Invoke-RestMethod -Method Post -Uri "$LoginEndpoint/$TenantId/oauth2/v2.0/token" -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $r.access_token
}

function Get-PpdfIdentityConfig {
    param($EnvSpec, [string]$Role)
    $ids = Get-PpdfValue $EnvSpec 'identities' @{}
    $id = Get-PpdfValue $ids $Role
    if (-not $id) { throw "No identity configured for role '$Role' in spec.identities." }
    return $id
}

function Connect-PpdfIdentity {
    <#
    .SYNOPSIS
    Connects to Security & Compliance PowerShell and/or Microsoft Graph as the purpose-specific identity for a role.
    #>
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)]$EnvSpec,
        [ValidateSet('scc', 'graph')][string[]]$Services = @('scc')
    )
    if ($env:PPDF_SKIP_CONNECT -eq '1' -or $script:SkipConnect) { Write-PpdfLog -Level debug -Message "PPDF_SKIP_CONNECT set; not connecting as '$Role'."; return }
    $key = "$Role|$($Services -join ',')"
    if ($script:Connection -eq $key) { return }
    Disconnect-PpdfIdentity

    $tenant = Get-PpdfValue $EnvSpec 'tenant'
    $tenantId = [string](Get-PpdfValue $tenant 'tenantId')
    $org = [string](Get-PpdfValue $tenant 'organization')
    $cloud = [string](Get-PpdfValue $tenant 'cloud' 'Commercial')
    $ep = Get-PpdfCloudEndpoint -Cloud $cloud
    $sccScope = [string](Get-PpdfValue $tenant 'sccTokenScope' $ep.SccScope)
    $idc = Get-PpdfIdentityConfig -EnvSpec $EnvSpec -Role $Role
    $clientId = [string](Get-PpdfValue $idc 'clientId')
    $mode = [string](Get-PpdfValue $idc 'authMode' 'federated')
    Write-PpdfLog -Message "Connecting as identity role '$Role' ($mode) to $($Services -join '+')" -Data @{ clientId = $clientId; cloud = $cloud }

    $assertion = $null
    if ($mode -eq 'federated') { $assertion = Get-PpdfFederatedToken -AdoServiceConnectionId ([string](Get-PpdfValue $idc 'adoServiceConnectionId')) }
    elseif ($mode -eq 'managedidentity-fic') { $assertion = Get-PpdfManagedIdentityAssertion -ManagedIdentityClientId ([string](Get-PpdfValue $idc 'managedIdentityClientId')) }

    if ('scc' -in $Services) {
        $p = @{ ShowBanner = $false }
        if ($ep.SccUri) { $p.ConnectionUri = $ep.SccUri; $p.AzureADAuthorizationEndpointUri = $ep.SccAuthority }
        switch ($mode) {
            { $_ -in 'federated', 'managedidentity-fic' } {
                $token = Get-PpdfAccessToken -TenantId $tenantId -ClientId $clientId -Assertion $assertion -Scope $sccScope -LoginEndpoint $ep.Login
                $p.AccessToken = $token
                $p.Organization = $org
            }
            'certificate' {
                $p.AppId = $clientId
                $p.Organization = $org
                $thumb = [string](Get-PpdfValue $idc 'certificateThumbprint' $env:PPDF_CERT_THUMBPRINT)
                $pfx = [string](Get-PpdfValue $idc 'certificatePath' $env:PPDF_CERT_PATH)
                if ($thumb) { $p.CertificateThumbprint = $thumb }
                elseif ($pfx) {
                    $p.CertificateFilePath = $pfx
                    if ($env:PPDF_CERT_PASSWORD) { $p.CertificatePassword = [System.Net.NetworkCredential]::new('', $env:PPDF_CERT_PASSWORD).SecurePassword }
                }
                else { throw "certificate authMode for role '$Role' requires certificateThumbprint or certificatePath." }
            }
            'interactive' { }
            default { throw "Unsupported authMode '$mode'." }
        }
        Connect-IPPSSession @p -ErrorAction Stop | Out-Null
    }
    if ('graph' -in $Services) {
        $g = @{ Environment = $ep.GraphEnvironment; NoWelcome = $true }
        switch ($mode) {
            { $_ -in 'federated', 'managedidentity-fic' } {
                $token = Get-PpdfAccessToken -TenantId $tenantId -ClientId $clientId -Assertion $assertion -Scope "$($ep.Graph)/.default" -LoginEndpoint $ep.Login
                $g.AccessToken = [System.Net.NetworkCredential]::new('', $token).SecurePassword
            }
            'certificate' {
                $g.ClientId = $clientId; $g.TenantId = $tenantId
                $g.CertificateThumbprint = [string](Get-PpdfValue $idc 'certificateThumbprint' $env:PPDF_CERT_THUMBPRINT)
            }
            'interactive' { $g.TenantId = $tenantId; $g.Scopes = @('RoleManagement.ReadWrite.Directory') }
        }
        Connect-MgGraph @g -ErrorAction Stop | Out-Null
    }
    $script:Connection = $key
}

function Disconnect-PpdfIdentity {
    if (-not $script:Connection) { return }
    if ($env:PPDF_SKIP_CONNECT -eq '1' -or $script:SkipConnect) { $script:Connection = $null; return }
    try { if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } } catch { Write-Verbose $_ }
    try { if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } } catch { Write-Verbose $_ }
    $script:Connection = $null
}

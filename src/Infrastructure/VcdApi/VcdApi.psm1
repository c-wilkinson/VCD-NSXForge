# Read-only VCD 10.6 contract; transport is injected. No HTTP implementation here.
Set-StrictMode -Version Latest

function New-VcdApiClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$BaseUri,
        [Parameter(Mandatory)][scriptblock]$RequestSender,
        [ValidatePattern('^\d+\.\d+$')][string]$ApiVersion = '39.0',
        [switch]$AllowLoopbackHttp
    )
    $safeLoopback = ($AllowLoopbackHttp -and $BaseUri.Scheme -ceq 'http' -and $BaseUri.Host -ceq '127.0.0.1')
    if (($BaseUri.Scheme -cne 'https' -and -not $safeLoopback) -or -not $BaseUri.IsAbsoluteUri) {
        # Non-default HTTPS ports are allowed for self-hosted instances.
        throw 'The VCD base URI must be an absolute HTTPS URI.'
    }
    if ($BaseUri.AbsolutePath -ne '/') { throw 'The VCD base URI must contain only the origin.' }
    [pscustomobject]@{
        BaseUri = $BaseUri
        ApiVersion = $ApiVersion
        RequestSender = $RequestSender
    }
}

function Invoke-VcdRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Path,
        [string]$Accept = '',
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    if (-not $Path.StartsWith('/') -or $Path.StartsWith('//') -or $Path -match '[\\]' -or $Path -match '(?:^|/)\.\.?(/|$)' -or $Path -match '[#]') {
        throw 'Invalid VCD relative API path.'
    }
    if (-not $Accept) { $Accept = "application/json;version=$($Client.ApiVersion)" }
    $url = [uri]::new($Client.BaseUri, $Path)
    # One injected boundary for all API operations: sender receives ONLY these values.
    & $Client.RequestSender ([pscustomobject]@{
        Method = 'GET'
        Uri = $url.AbsoluteUri
        Headers = @{ Accept = $Accept }
        CancellationToken = $CancellationToken
    })
}

function Get-VcdApiVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client,
          [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    $raw = Invoke-VcdRead -Client $Client -Path '/api/versions' -Accept 'application/*+xml' -CancellationToken $CancellationToken
    try {
        [xml]$document = [string]$raw
        @($document.SelectNodes('//*[local-name()="VersionInfo"]/*[local-name()="Version"]') | ForEach-Object { $_.InnerText })
    }
    catch { throw 'VCD version discovery response is not valid XML.' }
}

function Get-VcdEdgeFirewallRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GatewayId, [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    if ([string]::IsNullOrWhiteSpace($GatewayId)) { throw 'Gateway ID is required.' }
    $encoded = [uri]::EscapeDataString($GatewayId)
    Invoke-VcdRead -Client $Client -Path "/cloudapi/2.0.0/edgeGateways/$encoded/firewall/rules" -CancellationToken $CancellationToken
}

function Invoke-VcdPagedRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$ResourcePath,
        [Parameter(Mandatory)][string]$Filter,
        [ValidateRange(1,128)][int]$PageSize = 100,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    $accumulator = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 10000; $page++) {
        $query = '?filter={0}&page={1}&pageSize={2}' -f ([uri]::EscapeDataString($Filter)), $page, $PageSize
        $CancellationToken.ThrowIfCancellationRequested()
        $response = Invoke-VcdRead -Client $Client -Path ($ResourcePath + $query) -CancellationToken $CancellationToken
        if ($null -eq $response -or $null -eq $response.values) { throw 'VCD paging response is missing values.' }
        foreach ($item in @($response.values)) { $accumulator.Add($item) }
        if ($null -eq $response.pageCount) { throw 'VCD paging response is missing pageCount.' }
        if ($page -eq 1 -and [int]$response.pageCount -eq 0 -and @($response.values).Count -eq 0) {
            if ($null -ne $response.PSObject.Properties['resultTotal'] -and [int]$response.resultTotal -ne 0) {
                throw 'VCD pagination returned inconsistent totals for an empty result.'
            }
            return $accumulator.ToArray()
        }
        if ([int]$response.pageCount -lt $page) { throw 'VCD paging returned an invalid pageCount.' }
        if ($page -ge [int]$response.pageCount) {
            if ($null -ne $response.PSObject.Properties['resultTotal'] -and [int]$response.resultTotal -ne $accumulator.Count) {
                throw 'VCD pagination returned fewer or more items than resultTotal; snapshot is incomplete.'
            }
            return $accumulator.ToArray()
        }
    }
    throw 'VCD paging exceeded the 10000-page safety limit.'
}

function Get-VcdFirewallGroupDetails {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GroupId, [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    if ([string]::IsNullOrWhiteSpace($GroupId)) { throw 'Firewall Group ID is required.' }
    Invoke-VcdRead -Client $Client -Path ("/cloudapi/1.0.0/firewallGroups/" + [uri]::EscapeDataString($GroupId)) -CancellationToken $CancellationToken
}

function Get-VcdFirewallGroups {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GatewayId, [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    if ([string]::IsNullOrWhiteSpace($GatewayId)) { throw 'Gateway ID is required.' }
    Invoke-VcdPagedRead -Client $Client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter "(edgeGatewayId==$GatewayId)" -CancellationToken $CancellationToken
}

function Get-VcdManualIpReservations {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$NetworkId, [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    if ([string]::IsNullOrWhiteSpace($NetworkId)) { throw 'Network ID is required.' }
    Invoke-VcdPagedRead -Client $Client -ResourcePath '/cloudapi/1.0.0/manualIpReservations' -Filter "(networkRef.id==$NetworkId)" -CancellationToken $CancellationToken
}

Export-ModuleMember -Function New-VcdApiClient, Invoke-VcdRead, Get-VcdApiVersions, Get-VcdEdgeFirewallRules, Get-VcdFirewallGroupDetails, Invoke-VcdPagedRead, Get-VcdFirewallGroups, Get-VcdManualIpReservations

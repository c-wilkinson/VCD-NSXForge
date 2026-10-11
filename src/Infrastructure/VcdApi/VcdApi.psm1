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
    if ($BaseUri.AbsolutePath -ne '/' -or $BaseUri.UserInfo -or $BaseUri.Query -or $BaseUri.Fragment) { throw 'The VCD base URI must contain only the origin, with no credentials, query or fragment.' }
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
    $knownIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedPages = $null
    $expectedTotal = $null
    for ($page = 1; $page -le 10000; $page++) {
        $CancellationToken.ThrowIfCancellationRequested()
        $query = '?filter={0}&page={1}&pageSize={2}' -f ([uri]::EscapeDataString($Filter)), $page, $PageSize
        $response = Invoke-VcdRead -Client $Client -Path ($ResourcePath + $query) -CancellationToken $CancellationToken
        if ($null -eq $response -or $null -eq $response.values) { throw 'VCD paging response is missing values.' }
        if ($null -eq $response.pageCount) { throw 'VCD paging response is missing pageCount.' }

        # Metadata is required to agree across pages; accepting contradictory
        # totals makes a partial live snapshot look complete and safe to apply.
        $pages = 0
        if (-not [int]::TryParse([string]$response.pageCount, [ref]$pages) -or $pages -lt 0 -or $pages -gt 10000) {
            throw 'VCD paging response contains an invalid pageCount.'
        }
        if ($null -ne $expectedPages -and $expectedPages -ne $pages) {
            throw 'VCD paging pageCount changed during collection; snapshot is inconsistent.'
        }
        $expectedPages = $pages
        if ($null -ne $response.PSObject.Properties['page']) {
            $returnedPage = 0
            if (-not [int]::TryParse([string]$response.page, [ref]$returnedPage) -or
                ($returnedPage -ne $page -and -not ($pages -eq 0 -and $returnedPage -eq 0))) {
                throw 'VCD paging returned an unexpected page number.'
            }
        }
        if ($null -ne $response.PSObject.Properties['pageSize']) {
            $returnedSize = 0
            if (-not [int]::TryParse([string]$response.pageSize, [ref]$returnedSize) -or
                $returnedSize -lt 0 -or $returnedSize -gt $PageSize) {
                throw 'VCD paging returned an invalid pageSize.'
            }
        }
        if ($null -ne $response.PSObject.Properties['resultTotal']) {
            $total = 0
            if (-not [int]::TryParse([string]$response.resultTotal, [ref]$total) -or $total -lt 0) {
                throw 'VCD paging returned an invalid resultTotal.'
            }
            if ($null -ne $expectedTotal -and $expectedTotal -ne $total) {
                throw 'VCD paging resultTotal changed during collection; snapshot is inconsistent.'
            }
            $expectedTotal = $total
        }

        $items = @($response.values)
        if ($pages -eq 0) {
            if ($items.Count -ne 0 -or ($null -ne $expectedTotal -and $expectedTotal -ne 0)) {
                throw 'VCD pagination returned inconsistent totals for an empty result.'
            }
            return $accumulator.ToArray()
        }
        if ($page -gt $pages -or ($page -lt $pages -and $items.Count -eq 0)) {
            throw 'VCD paging returned an invalid or empty intermediate page.'
        }
        if ($items.Count -gt $PageSize) { throw 'VCD paging response exceeded requested pageSize.' }
        foreach ($item in $items) {
            if ($null -ne $item -and $null -ne $item.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) {
                if (-not $knownIds.Add([string]$item.id)) { throw 'VCD pagination repeated an object ID; snapshot is inconsistent.' }
            }
            $accumulator.Add($item)
        }
        if ($null -ne $expectedTotal -and $accumulator.Count -gt $expectedTotal) {
            throw 'VCD paging returned more objects than resultTotal.'
        }
        if ($page -eq $pages) {
            if ($null -ne $expectedTotal -and $expectedTotal -ne $accumulator.Count) {
                throw 'VCD pagination returned fewer or more items than resultTotal; snapshot is incomplete.'
            }
            return $accumulator.ToArray()
        }
    }
    throw 'VCD paging exceeded the 10000-page safety limit.'
}

# Resolve server-owned resource metadata before a live operation uses caller-provided IDs.
function Get-VcdGatewayOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GatewayId,
          [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    Invoke-VcdRead -Client $Client -Path ('/cloudapi/1.0.0/edgeGateways/' + [uri]::EscapeDataString($GatewayId)) -CancellationToken $CancellationToken
}

function Get-VcdNetworkOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$NetworkId,
          [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    Invoke-VcdRead -Client $Client -Path ('/cloudapi/1.0.0/orgVdcNetworks/' + [uri]::EscapeDataString($NetworkId)) -CancellationToken $CancellationToken
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

Export-ModuleMember -Function New-VcdApiClient, Invoke-VcdRead, Get-VcdApiVersions, Get-VcdEdgeFirewallRules, Get-VcdFirewallGroupDetails, Invoke-VcdPagedRead, Get-VcdFirewallGroups, Get-VcdManualIpReservations, Get-VcdGatewayOwnership, Get-VcdNetworkOwnership

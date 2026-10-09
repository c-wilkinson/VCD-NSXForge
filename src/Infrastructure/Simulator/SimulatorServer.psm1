# Local-only VCD 10.6 shaped read-only simulator; no real VMware/AD resources.
Set-StrictMode -Version Latest
# Import the shared topology module without reloading it. A forced nested import
# can remove the caller's exported commands during PowerShell 5.1 test runs.
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop

function New-SimulatorResult {
    param([int]$StatusCode=200, $Body, [string]$ContentType='application/json; charset=utf-8')
    [pscustomobject]@{ StatusCode=$StatusCode; Body=$Body; ContentType=$ContentType }
}

function Get-SimulatorPage {
    param([object[]]$Items, [int]$Page, [int]$PageSize)
    if ($Page -lt 1 -or $PageSize -lt 1 -or $PageSize -gt 128) { return $null }
    $total = @($Items).Count
    $pages = [int][math]::Ceiling($total / [double]$PageSize)
    $offset = ($Page - 1) * $PageSize
    $values = if ($offset -lt $total) { @($Items | Select-Object -Skip $offset -First $PageSize) } else { @() }
    [pscustomobject]@{ page=$Page; pageSize=$PageSize; pageCount=$pages; resultTotal=$total; values=@($values) }
}

function Invoke-SimulatorRoute {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,
          [Parameter(Mandatory)][string]$Method,
          [Parameter(Mandatory)][string]$Path,
          [hashtable]$Query = @{},
          [string]$Authorization = '')
    if ($Method -cnotin @('GET','POST')) { return New-SimulatorResult -StatusCode 405 -Body @{ error='Method not allowed' } }
    if ($Method -ceq 'GET' -and $Path -ceq '/api/versions') {
        return New-SimulatorResult -ContentType 'application/xml; charset=utf-8' -Body '<SupportedVersions><VersionInfo><Version>39.0</Version></VersionInfo></SupportedVersions>'
    }
    if ($Method -ceq 'POST' -and $Path -in @('/cloudapi/1.0.0/sessions','/cloudapi/1.0.0/sessions/provider')) {
        # Only the designated synthetic username and password work here. Never enter real credentials.
        $expected = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('simulator@local:simulator-only'))
        if ($Authorization -cne $expected) { return New-SimulatorResult -StatusCode 401 -Body @{error='Synthetic simulator credentials only'} }
        return New-SimulatorResult -Body @{ id='urn:vcloud:session:simulator'; token='simulator-read-only' }
    }
    if ($Method -cne 'GET') { return New-SimulatorResult -StatusCode 405 -Body @{error='Read-only simulator: mutation requests are rejected'} }
    if ($Path -ceq '/__simulator/v1/topology') {
        return New-SimulatorResult -Body @{synthetic=$true;domains=$Dataset.domains;managementGrants=$Dataset.managementGrants;gateways=@($Dataset.gateways | ForEach-Object { [pscustomobject]@{domain=$_.domain;tier=$_.tier;gatewayId=$_.gatewayId;networkId=$_.networkId;name=$_.name} }) }
    }
    if ($Path -ceq '/__simulator/v1/access') {
        foreach ($required in @('sourceDomain','sourceTier','targetDomain','targetTier')) {
            if (-not $Query.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$Query[$required])) {
                return New-SimulatorResult -StatusCode 400 -Body @{error='Incomplete access-check parameters'}
            }
        }
        try {
            $decision = Get-SimulatorAccessDecision -Dataset $Dataset -SourceDomain ([string]$Query.sourceDomain) -SourceTier ([int]$Query.sourceTier) -TargetDomain ([string]$Query.targetDomain) -TargetTier ([int]$Query.targetTier)
            return New-SimulatorResult -Body $decision
        }
        catch { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid access-check parameters'} }
    }
    if ($Authorization -cne 'Bearer simulator-read-only') { return New-SimulatorResult -StatusCode 401 -Body @{error='Invalid synthetic bearer token'} }
    if ($Path -ceq '/cloudapi/1.0.0/sessions/current') {
        return New-SimulatorResult -Body @{id='urn:vcloud:session:simulator';user='simulator@local';org='simulator';synthetic=$true}
    }
    if ($Path -cmatch '^/cloudapi/2\.0\.0/edgeGateways/([^/]+)/firewall/rules$') {
        $id = [uri]::UnescapeDataString($matches[1]); $gateway = @($Dataset.gateways | Where-Object { $_.gatewayId -ceq $id })
        if ($gateway.Count -ne 1) { return New-SimulatorResult -StatusCode 404 -Body @{error='Synthetic gateway not found'} }
        return New-SimulatorResult -Body $gateway[0].firewall
    }
    if ($Path -ceq '/cloudapi/1.0.0/firewallGroups/summaries') {
        if (-not $Query.ContainsKey('filter')) { return New-SimulatorResult -StatusCode 400 -Body @{error='Missing gateway filter'} }
        $match = [regex]::Match([string]$Query.filter, '^\(edgeGatewayId==(urn:vcloud:gateway:[0-9a-f-]{36})\)$')
        if (-not $match.Success) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid gateway filter'} }
        $gateway = @($Dataset.gateways | Where-Object { $_.gatewayId -ceq $match.Groups[1].Value })
        if ($gateway.Count -ne 1) { return New-SimulatorResult -StatusCode 404 -Body @{error='Gateway not found'} }
        $items = @($gateway[0].ipSets | ForEach-Object { [pscustomobject]@{id=$_.id;name=$_.name;typeValue=$_.typeValue} })
        $page = 1; $pageSize = 100
        if ($Query.ContainsKey('page') -and -not [int]::TryParse([string]$Query.page,[ref]$page)) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid page'} }
        if ($Query.ContainsKey('pageSize') -and -not [int]::TryParse([string]$Query.pageSize,[ref]$pageSize)) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid page size'} }
        $result = Get-SimulatorPage -Items $items -Page $page -PageSize $pageSize
        if ($null -eq $result) { return New-SimulatorResult -StatusCode 400 -Body @{error='Pagination out of bounds'} }
        return New-SimulatorResult -Body $result
    }
    if ($Path -cmatch '^/cloudapi/1\.0\.0/firewallGroups/([^/]+)$') {
        $id = [uri]::UnescapeDataString($matches[1]); $groups = @($Dataset.gateways | ForEach-Object { $_.ipSets } | Where-Object { $_.id -ceq $id })
        if ($groups.Count -ne 1) { return New-SimulatorResult -StatusCode 404 -Body @{error='IP Set not found'} }
        return New-SimulatorResult -Body $groups[0]
    }
    if ($Path -ceq '/cloudapi/1.0.0/manualIpReservations') {
        if (-not $Query.ContainsKey('filter')) { return New-SimulatorResult -StatusCode 400 -Body @{error='Missing network filter'} }
        $match = [regex]::Match([string]$Query.filter, '^\(networkRef\.id==(urn:vcloud:network:[0-9a-f-]{36})\)$')
        if (-not $match.Success) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid network filter'} }
        $gateway = @($Dataset.gateways | Where-Object { $_.networkId -ceq $match.Groups[1].Value })
        if ($gateway.Count -ne 1) { return New-SimulatorResult -StatusCode 404 -Body @{error='Network not found'} }
        $page = 1; $pageSize = 100
        if ($Query.ContainsKey('page') -and -not [int]::TryParse([string]$Query.page,[ref]$page)) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid page'} }
        if ($Query.ContainsKey('pageSize') -and -not [int]::TryParse([string]$Query.pageSize,[ref]$pageSize)) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid page size'} }
        $result = Get-SimulatorPage -Items @($gateway[0].reservations) -Page $page -PageSize $pageSize
        if ($null -eq $result) { return New-SimulatorResult -StatusCode 400 -Body @{error='Pagination out of bounds'} }
        return New-SimulatorResult -Body $result
    }
    return New-SimulatorResult -StatusCode 404 -Body @{error='Simulator endpoint not implemented'}
}

function Start-VcdSimulatorServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TopologyPath,
          [ValidateRange(1024,65535)][int]$Port=8765)
    $dataset = Import-SimulatorTopology -Path $TopologyPath
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))
    try {
        try { $listener.Start() }
        catch [System.Net.HttpListenerException] {
            throw "Could not start loopback simulator on port $Port ($($_.Exception.Message)). Check URL ACL and whether the port is already in use."
        }
        Write-Host ("Synthetic VCD 10.6 API simulator at http://127.0.0.1:{0}/" -f $Port) -ForegroundColor Cyan
        Write-Host 'Read-only. No actual VMware or Active Directory connections. Press Ctrl+C to stop.'
        while ($listener.IsListening) {
            $pending = $listener.BeginGetContext($null, $null)
            while (-not $pending.AsyncWaitHandle.WaitOne(250)) { }
            $context = $listener.EndGetContext($pending)
            try {
                $remote = $context.Request.RemoteEndPoint.Address
                if (-not [Net.IPAddress]::IsLoopback($remote)) {
                    $result = New-SimulatorResult -StatusCode 403 -Body @{error='Loopback clients only'}
                }
                else {
                    $query = @{}
                    foreach ($key in @($context.Request.QueryString.AllKeys)) { if ($null -ne $key) { $query[$key] = $context.Request.QueryString[$key] } }
                    $result = Invoke-SimulatorRoute -Dataset $dataset -Method $context.Request.HttpMethod -Path $context.Request.Url.AbsolutePath -Query $query -Authorization ([string]$context.Request.Headers['Authorization'])
                }
                $content = if ($result.Body -is [string]) { [string]$result.Body } else { ConvertTo-Json -InputObject $result.Body -Depth 40 -Compress }
                $bytes = [Text.Encoding]::UTF8.GetBytes($content)
                $context.Response.StatusCode = [int]$result.StatusCode
                $context.Response.ContentType = $result.ContentType
                if ($context.Request.HttpMethod -ceq 'POST' -and $context.Request.Url.AbsolutePath -in @('/cloudapi/1.0.0/sessions','/cloudapi/1.0.0/sessions/provider') -and $result.StatusCode -eq 200) {
                    # Synthetic token header matches what the real read client expects from session login.
                    $context.Response.Headers.Add('X-VMWARE-VCLOUD-ACCESS-TOKEN','simulator-read-only')
                }
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
            }
            catch {
                Write-Warning 'Local simulator request failed (details suppressed).'
                if ($context.Response.OutputStream.CanWrite) { $context.Response.StatusCode = 500 }
            }
            finally { $context.Response.Close() }
        }
    }
    finally { if ($listener.IsListening) { $listener.Stop() }; $listener.Close() }
}

Export-ModuleMember -Function Invoke-SimulatorRoute, Start-VcdSimulatorServer

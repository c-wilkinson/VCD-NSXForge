# Local-only VCD 10.6 shaped simulator; synthetic writes never reach real VMware/AD.
Set-StrictMode -Version Latest
# Import the shared topology module without reloading it. A forced nested import
# can remove the caller's exported commands during PowerShell 5.1 test runs.
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'SimulatorWorkspace.psm1') -ErrorAction Stop

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

# Convert private simulator rule properties into the documented API 39.0
# firewall response shape. Never pass simulatorServices to live policy readers.
# The internal simulator workspace retains the original service list so local
# edits and first-match traffic decisions continue to use the same model.
function Get-SimulatorVcdFirewall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Gateway)
    $rules=@()
    foreach ($rule in @($Gateway.firewall.userDefinedRules)) {
        $fields=[ordered]@{}
        foreach ($prop in @($rule.PSObject.Properties)) {
            if ($prop.Name -cne 'simulatorServices') { $fields[$prop.Name]=$prop.Value }
        }
        if ($null -ne $rule.PSObject.Properties['simulatorServices']) {
            $profiles=@()
            foreach ($service in @($rule.simulatorServices)) {
                if ([string]$service.protocol -eq 'ANY') { continue }
                $profiles+= [pscustomobject]@{protocol=[string]$service.protocol;ports=(@($service.ports) -join ',')}
            }
            if ($profiles.Count -gt 0) { $fields['rawPortProtocols']=@($profiles) }
        }
        $rules+= [pscustomobject]$fields
    }
    return [pscustomobject]@{
        status=[string]$Gateway.firewall.status
        systemRules=@($Gateway.firewall.systemRules)
        userDefinedRules=@($rules)
        defaultRules=@($Gateway.firewall.defaultRules)
    }
}

# A stable, bounded stream of fictional flows. Each tick advances through the
# curated enterprise cases, so repeated runs and tests are reproducible.
# Traffic is evaluated against CURRENT simulated firewall rules; a changed
# rule changes subsequent outcomes. No packets are sent anywhere.
function New-SimulatorTrafficSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,[Parameter(Mandatory)][string]$CasesPath)
    $data=Get-Content -LiteralPath $CasesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.schemaVersion -ne 1 -or $data.synthetic -ne $true -or @($data.cases).Count -lt 1 -or @($data.cases).Count -gt 256) {
        throw 'Invalid synthetic background traffic fixture.'
    }
    $known=@{}; foreach ($gw in @($Dataset.gateways)) { $known[[string]$gw.gatewayId]=$true }
    # Interleave gateways: samples from every domain/tier appear promptly, even
    # though the fixture contains more DomainB Tier 1 traffic than others.
    $groups=[ordered]@{}
    foreach ($case in @($data.cases)) {
        if (-not $known.ContainsKey([string]$case.gatewayId) -or
            [string]$case.protocol -cnotin @('TCP','UDP','ICMP') -or
            [int]$case.destinationPort -lt 0 -or [int]$case.destinationPort -gt 65535) {
            throw 'Background traffic fixture refers to an invalid gateway or service.'
        }
        $id=[string]$case.gatewayId
        if (-not $groups.Contains($id)) { $groups[$id]=[System.Collections.Generic.List[object]]::new() }
        $groups[$id].Add($case)
    }
    $ordered=[System.Collections.Generic.List[object]]::new()
    $max=0; foreach ($group in $groups.Values) { $max=[Math]::Max($max,$group.Count) }
    for ($i=0; $i -lt $max; $i++) {
        foreach ($group in $groups.Values) { if ($i -lt $group.Count) { $ordered.Add($group[$i]) } }
    }
    return [pscustomobject]@{cases=@($ordered.ToArray());index=0;generated=0}
}

function Invoke-SimulatorTrafficTick {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,[Parameter(Mandatory)]$Schedule)
    if (@($Schedule.cases).Count -eq 0) { throw 'Background traffic schedule is empty.' }
    $case=$Schedule.cases[[int]$Schedule.index]
    $request=[pscustomobject]@{
        gatewayId=[string]$case.gatewayId
        sourceIp=[string]$case.sourceIp
        destinationIp=[string]$case.destinationIp
        protocol=[string]$case.protocol
        destinationPort=[int]$case.destinationPort
    }
    $result=Invoke-SimulatorTraffic -Dataset $Dataset -Request $request
    $Schedule.index=([int]$Schedule.index+1) % @($Schedule.cases).Count
    $Schedule.generated=[int]$Schedule.generated+1
    return $result
}

function Invoke-SimulatorRoute {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,
          [Parameter(Mandatory)][string]$Method,
          [Parameter(Mandatory)][string]$Path,
          [hashtable]$Query = @{},
          [string]$Authorization = '',
          $RequestBody = $null)
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
    # Simulator-only POSTs are an entirely separate namespace from VCD API writes.
    # A dedicated fake token is required for simulator writes. Never use live VCD credentials.
    if ($Path -in @('/__simulator/v1/apply','/__simulator/v1/traffic') -and $Method -ceq 'POST') {
        if ($Authorization -cne 'Bearer simulator-edit-only') { return New-SimulatorResult -StatusCode 403 -Body @{error='Synthetic edit token required'} }
        if ($null -eq $RequestBody) { return New-SimulatorResult -StatusCode 400 -Body @{error='Missing request JSON'} }
        try {
            if ($Path -eq '/__simulator/v1/apply') {
                return New-SimulatorResult -Body (Invoke-SimulatorApply -Dataset $Dataset -Request $RequestBody)
            }
            return New-SimulatorResult -Body (Invoke-SimulatorTraffic -Dataset $Dataset -Request $RequestBody)
        }
        catch {
            $status = if ($_.Exception.Message -like '409:*') { 409 } elseif ($_.Exception.Message -like '403:*') { 403 } else { 422 }
            return New-SimulatorResult -StatusCode $status -Body @{error=$_.Exception.Message}
        }
    }
    if ($Method -cne 'GET') { return New-SimulatorResult -StatusCode 405 -Body @{error='VCD API mutations are never implemented by the simulator'} }
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
    if ($Authorization -cnotin @('Bearer simulator-read-only','Bearer simulator-edit-only')) { return New-SimulatorResult -StatusCode 401 -Body @{error='Invalid synthetic bearer token'} }
    if ($Path -ceq '/__simulator/v1/scopes') {
        return New-SimulatorResult -Body @{synthetic=$true;scopes=@($Dataset.gateways | ForEach-Object { [pscustomobject]@{domain=$_.domain;tier=$_.tier;gatewayId=$_.gatewayId;networkId=$_.networkId;name=$_.name} })}
    }
    if ($Path -ceq '/__simulator/v1/state') {
        try { return New-SimulatorResult -Body (Get-SimulatorWorkspaceState -Dataset $Dataset -GatewayId ([string]$Query.gatewayId)) }
        catch { return New-SimulatorResult -StatusCode 404 -Body @{error='Unknown synthetic gateway'} }
    }
    if ($Path -ceq '/__simulator/v1/traffic') {
        try {
            $null=Get-SimulatorWorkspaceState -Dataset $Dataset -GatewayId ([string]$Query.gatewayId)
            return New-SimulatorResult -Body @{synthetic=$true;events=@($Dataset.simulatorWorkspace[[string]$Query.gatewayId].flows)}
        }
        catch { return New-SimulatorResult -StatusCode 404 -Body @{error='Unknown synthetic gateway'} }
    }
    # API 39.0 discovery fixtures are synthetic, GET-only and tenant-scoped.
    # Model one synthetic organisation and one VDC per domain/tier so engineers
    # can exercise the same hierarchy used by real VCD clients.
    if ($Path -cin @('/cloudapi/1.0.0/orgs','/cloudapi/1.0.0/vdcs','/cloudapi/1.0.0/edgeGateways','/cloudapi/1.0.0/orgVdcNetworks')) {
        $org = 'urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $orgRef = [pscustomobject]@{ id = $org; name = 'Synthetic organisation' }
        $items = @()
        switch ($Path) {
            '/cloudapi/1.0.0/orgs' { $items = @([pscustomobject]@{id=$org;name='Synthetic organisation'}) }
            '/cloudapi/1.0.0/vdcs' {
                $items = @($Dataset.gateways | ForEach-Object {
                    [pscustomobject]@{id=('urn:vcloud:vdc:{0}' -f $_.gatewayId.Substring($_.gatewayId.LastIndexOf(':')+1));name=('{0} Tier {1}' -f $_.domain,$_.tier);org=$orgRef}
                })
            }
            '/cloudapi/1.0.0/edgeGateways' {
                $items = @($Dataset.gateways | ForEach-Object {
                    [pscustomobject]@{id=$_.gatewayId;name=$_.name;vcdVersion='10.6';gatewayMode='NSXT_BACKED';networkBacking='NSX_T';synthetic=$true;orgRef=$orgRef;orgVdc=[pscustomobject]@{id=('urn:vcloud:vdc:{0}' -f $_.gatewayId.Substring($_.gatewayId.LastIndexOf(':')+1))}}
                })
            }
            '/cloudapi/1.0.0/orgVdcNetworks' {
                $items = @($Dataset.gateways | ForEach-Object {
                    [pscustomobject]@{id=$_.networkId;name=($_.name+' network');networkType='NAT_ROUTED';orgRef=$orgRef;orgVdc=[pscustomobject]@{id=('urn:vcloud:vdc:{0}' -f $_.gatewayId.Substring($_.gatewayId.LastIndexOf(':')+1))};connection=[pscustomobject]@{routerRef=[pscustomobject]@{id=$_.gatewayId}}}
                })
            }
        }
        $page=1;$pageSize=25
        if ($Query.ContainsKey('page') -and -not [int]::TryParse([string]$Query.page,[ref]$page)) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid discovery page'} }
        if ($Query.ContainsKey('pageSize') -and -not [int]::TryParse([string]$Query.pageSize,[ref]$pageSize)) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid discovery page size'} }
        $limit = if ($Path -eq '/cloudapi/1.0.0/orgVdcNetworks') { 32 } else { 128 }
        if ($pageSize -gt $limit) { return New-SimulatorResult -StatusCode 400 -Body @{error='Discovery page size too large'} }
        $result = Get-SimulatorPage -Items $items -Page $page -PageSize $pageSize
        if ($null -eq $result) { return New-SimulatorResult -StatusCode 400 -Body @{error='Invalid discovery pagination'} }
        return New-SimulatorResult -Body $result
    }
    if ($Path -cmatch '^/cloudapi/1\.0\.0/edgeGateways/([^/]+)$') {
        $id=[uri]::UnescapeDataString($matches[1])
        $matched=@($Dataset.gateways | Where-Object { $_.gatewayId -ceq $id })
        if ($matched.Count -ne 1) { return New-SimulatorResult -StatusCode 404 -Body @{error='Synthetic gateway not found'} }
        $org=[pscustomobject]@{id='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}
        return New-SimulatorResult -Body ([pscustomobject]@{
            id=$id;name=[string]$matched[0].name;vcdVersion='10.6';gatewayMode='NSXT_BACKED';networkBacking='NSX_T'
            synthetic=$true;orgRef=$org
            orgVdc=[pscustomobject]@{id=('urn:vcloud:vdc:{0}' -f $id.Substring($id.LastIndexOf(':')+1))}
        })
    }
    if ($Path -ceq '/cloudapi/1.0.0/sessions/current') {
        return New-SimulatorResult -Body @{id='urn:vcloud:session:simulator';user='simulator@local';org='simulator';orgRef=[pscustomobject]@{id='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'};synthetic=$true}
    }
    if ($Path -cmatch '^/cloudapi/2\.0\.0/edgeGateways/([^/]+)/firewall/rules$') {
        $id = [uri]::UnescapeDataString($matches[1]); $gateway = @($Dataset.gateways | Where-Object { $_.gatewayId -ceq $id })
        if ($gateway.Count -ne 1) { return New-SimulatorResult -StatusCode 404 -Body @{error='Synthetic gateway not found'} }
        return New-SimulatorResult -Body (Get-SimulatorVcdFirewall -Gateway $gateway[0])
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
          [ValidateRange(1024,65535)][int]$Port=8765,
          [string]$PersistencePath='',
          [string]$TrafficCasesPath='',
          [ValidateRange(1,60)][int]$TrafficIntervalSeconds=2)
    $dataset = Import-SimulatorTopology -Path $TopologyPath
    $null = Initialize-SimulatorWorkspace -Dataset $dataset -PersistencePath $PersistencePath
    $trafficSchedule=$null
    if ($TrafficCasesPath) {
        $trafficSchedule=New-SimulatorTrafficSchedule -Dataset $dataset -CasesPath $TrafficCasesPath
    }
    $nextTraffic=[DateTime]::UtcNow.AddSeconds($TrafficIntervalSeconds)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))
    try {
        try { $listener.Start() }
        catch [System.Net.HttpListenerException] {
            throw "Could not start loopback simulator on port $Port ($($_.Exception.Message)). Check URL ACL and whether the port is already in use."
        }
        Write-Host ("Synthetic VCD 10.6 API simulator at http://127.0.0.1:{0}/" -f $Port) -ForegroundColor Cyan
        Write-Host 'Local synthetic edits enabled only via /__simulator/v1/apply. No actual VMware/AD changes. Press Ctrl+C to stop.'
        if ($null -ne $trafficSchedule) { Write-Host ('Synthetic traffic generator running every {0}s; monitoring GET remains read-only.' -f $TrafficIntervalSeconds) -ForegroundColor Cyan }
        while ($listener.IsListening) {
            $pending = $listener.BeginGetContext($null, $null)
            while (-not $pending.AsyncWaitHandle.WaitOne(250)) {
                if ($null -ne $trafficSchedule -and [DateTime]::UtcNow -ge $nextTraffic) {
                    try { $null=Invoke-SimulatorTrafficTick -Dataset $dataset -Schedule $trafficSchedule }
                    catch { Write-Warning 'Synthetic traffic generation failed; monitoring stays available.' }
                    $nextTraffic=[DateTime]::UtcNow.AddSeconds($TrafficIntervalSeconds)
                }
            }
            # Requests arriving continuously must not starve the generator.
            if ($null -ne $trafficSchedule -and [DateTime]::UtcNow -ge $nextTraffic) {
                try { $null=Invoke-SimulatorTrafficTick -Dataset $dataset -Schedule $trafficSchedule }
                catch { Write-Warning 'Synthetic traffic generation failed; monitoring stays available.' }
                $nextTraffic=[DateTime]::UtcNow.AddSeconds($TrafficIntervalSeconds)
            }
            $context = $listener.EndGetContext($pending)
            try {
                $result = $null
                $remote = $context.Request.RemoteEndPoint.Address
                if (-not [Net.IPAddress]::IsLoopback($remote)) {
                    $result = New-SimulatorResult -StatusCode 403 -Body @{error='Loopback clients only'}
                }
                else {
                    $query = @{}
                    foreach ($key in @($context.Request.QueryString.AllKeys)) { if ($null -ne $key) { $query[$key] = $context.Request.QueryString[$key] } }
                    $requestBody = $null
                    if ($context.Request.HttpMethod -ceq 'POST' -and $context.Request.Url.AbsolutePath -in @('/__simulator/v1/apply','/__simulator/v1/traffic')) {
                        if ($context.Request.ContentLength64 -lt 0 -or $context.Request.ContentLength64 -gt 1048576) {
                            $result = New-SimulatorResult -StatusCode 413 -Body @{error='JSON request exceeds 1 MiB maximum'}
                        }
                        else {
                            try {
                                $reader = [IO.StreamReader]::new($context.Request.InputStream,[Text.Encoding]::UTF8)
                                $bodyText = $reader.ReadToEnd()
                                $reader.Dispose()
                                $requestBody = ConvertFrom-Json -InputObject $bodyText -ErrorAction Stop
                            }
                            catch { $result = New-SimulatorResult -StatusCode 400 -Body @{error='Invalid JSON request'} }
                        }
                    }
                    if ($null -eq $result) {
                        $result = Invoke-SimulatorRoute -Dataset $dataset -Method $context.Request.HttpMethod -Path $context.Request.Url.AbsolutePath -Query $query -Authorization ([string]$context.Request.Headers['Authorization']) -RequestBody $requestBody
                    }
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

Export-ModuleMember -Function Invoke-SimulatorRoute, Start-VcdSimulatorServer, Get-SimulatorVcdFirewall, New-SimulatorTrafficSchedule, Invoke-SimulatorTrafficTick

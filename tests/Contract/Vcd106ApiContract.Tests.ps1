Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdSnapshot.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdApi.psm1') -Force -Global -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\VcdPolicyModel.psm1') -Global -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\State\VcdPolicyRepository.psm1') -Global -ErrorAction Stop
. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcd106.ps1')

function Assert-Vcd106Throws {
    param([Parameter(Mandatory)][scriptblock]$Body,
          [string]$Because = 'Expected an exception')
    $didThrow = $false
    try { & $Body | Out-Null }
    catch {
        $didThrow = $true
        if ($_.Exception -is [System.Management.Automation.CommandNotFoundException] -or
            [string]$_.FullyQualifiedErrorId -match 'CommandNotFoundException') {
            throw ('VCD 10.6 test invoked an unavailable command: ' + $_.Exception.Message)
        }
    }
    if (-not $didThrow) { throw $Because }
}

Invoke-TestCase -Name '10.6 prerequisite commands are exported into the test runner' -Body {
    foreach ($functionName in @(
        'New-VcdApiClient', 'Invoke-VcdRead', 'Get-VcdApiVersions',
        'Get-VcdEdgeFirewallRules', 'Get-VcdFirewallGroups',
        'Get-VcdFirewallGroupDetails', 'Get-VcdManualIpReservations',
        'Invoke-VcdPagedRead', 'Get-VcdReadSnapshot',
        'ConvertTo-VcdObservedDocuments', 'Save-VcdRawSnapshot',
        'ConvertTo-VcdPolicyDocument', 'Save-VcdPolicyObserved',
        'Invoke-VcdReadOperation', 'New-VcdHttpTransport',
        'Connect-VcdHttpTransport', 'Close-VcdHttpTransport'
    )) {
        $command = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
        Assert-True ($null -ne $command) ("Missing contract dependency: $functionName")
    }
}

Invoke-TestCase -Name '10.6 negative assertions reject missing commands and unexpected success' -Body {
    Assert-Vcd106Throws { throw 'Expected contract rejection' }
    $missingCommand = ''
    try { Assert-Vcd106Throws { Invoke-Vcd106CommandDoesNotExist } }
    catch { $missingCommand = $_.Exception.Message }
    Assert-True ($missingCommand -match 'unavailable command') 'An unknown command must fail the negative assertion'
    $unexpectedSuccess = ''
    try { Assert-Vcd106Throws { $null = 1 } }
    catch { $unexpectedSuccess = $_.Exception.Message }
    Assert-True ($unexpectedSuccess -match 'Expected an exception') 'An operation that succeeds must fail the negative assertion'
}

function New-Vcd106TestClient {
    param([scriptblock]$Sender)
    return (New-VcdApiClient -BaseUri ([uri]'https://vcd.example.test:8443') -RequestSender $Sender -ApiVersion '39.0')
}

function New-Vcd106LegacyCompatibleSnapshot {
    # The deliberately narrow subset the existing observed-state model understands.
    # It is NOT the real 10.6 snapshot: the real fixture tests must remain lossless.
    $folder = Join-Path $ProjectRoot 'tests\Fixtures\Phase3'
    $firewall = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $folder 'firewall.json')))
    $group = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $folder 'group.json')))
    $reservations = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $folder 'reservations.json')))
    return [pscustomobject]@{
        gatewayId = 'urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
        networkIds = @('urn:vcloud:network:44444444-4444-4444-8444-444444444444')
        firewall = $firewall
        ipSetDetails = @($group)
        manualIpReservations = @($reservations.values)
    }
}

function New-Vcd106PagedClient {
    param([scriptblock]$PageSender)
    return (New-VcdApiClient -BaseUri ([uri]'https://vcd.example.test:8443') -RequestSender $PageSender)
}

Invoke-TestCase -Name '10.6 fixture corpus parses and declares the API 39.0 baseline' -Body {
    $v = Read-Vcd106Fixture 'versions.xml'
    [xml]$parsed = $v
    Assert-True ($null -ne $parsed.DocumentElement)
    $fw = Read-Vcd106Fixture 'edge-firewall-rules.json'
    Assert-Equal 'REALIZED' $fw.status
    Assert-Equal 1 (@($fw.systemRules).Count)
    Assert-Equal 2 (@($fw.userDefinedRules).Count)
    Assert-Equal 1 (@($fw.defaultRules).Count)
    foreach ($name in @('firewall-groups-page1.json','firewall-groups-page2.json','firewall-group-ipset.json','manual-ip-reservations.json','session-current.json')) {
        Assert-True ($null -ne (Read-Vcd106Fixture $name)) "Bad fixture $name"
    }
}

Invoke-TestCase -Name '10.6 version discovery handles namespace-qualified XML and selects 39.0' -Body {
    $fake = New-FakeVcd106
    $client = New-Vcd106TestClient -Sender $fake.RequestSender
    $versions = @(Get-VcdApiVersions -Client $client)
    Assert-Equal 2 $versions.Count
    Assert-True ($versions -contains '39.0')
    Assert-Equal '/api/versions' ([uri]$fake.Calls[0].Uri).AbsolutePath
    Assert-Equal 'application/*+xml' $fake.Calls[0].Headers.Accept
}

Invoke-TestCase -Name '10.6 live API calls pin application/json version 39.0' -Body {
    $fake = New-FakeVcd106
    $client = New-Vcd106TestClient -Sender $fake.RequestSender
    $null = Get-VcdEdgeFirewallRules -Client $client -GatewayId $fake.GatewayId
    Assert-Equal 'GET' $fake.Calls[0].Method
    Assert-Equal 'application/json;version=39.0' $fake.Calls[0].Headers.Accept
}

Invoke-TestCase -Name '10.6 current-session read uses tenant-session endpoint and GET' -Body {
    $fake = New-FakeVcd106
    $result = Invoke-VcdRead -Client (New-Vcd106TestClient -Sender $fake.RequestSender) -Path '/cloudapi/1.0.0/sessions/current'
    Assert-True ($result.id -like 'urn:vcloud:session:*')
    Assert-Equal 1 $fake.Calls.Count
}

Invoke-TestCase -Name '10.6 v2 Edge firewall read retains all three rule sections and advanced fields' -Body {
    $fake = New-FakeVcd106
    $firewall = Get-VcdEdgeFirewallRules -Client (New-Vcd106TestClient -Sender $fake.RequestSender) -GatewayId $fake.GatewayId
    Assert-Equal 1 (@($firewall.systemRules).Count)
    Assert-Equal 2 (@($firewall.userDefinedRules).Count)
    Assert-Equal 1 (@($firewall.defaultRules).Count)
    Assert-Equal 'SQL-TCP-1433' $firewall.userDefinedRules[0].applicationPortProfiles[0].name
    Assert-Equal 'IN_OUT' $firewall.userDefinedRules[0].direction
    Assert-Equal 7 $firewall.userDefinedRules[0].version.version
    Assert-Equal $fake.GatewayId $firewall.userDefinedRules[0].appliedTo.id
    Assert-True ($firewall.userDefinedRules[0].enabled -is [bool])
}

Invoke-TestCase -Name '10.6 firewall groups use encoded gateway FIQL and consistent 1-based paging' -Body {
    $fake = New-FakeVcd106
    $client = New-Vcd106TestClient -Sender $fake.RequestSender
    $groups = @(Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter "(edgeGatewayId==$($fake.GatewayId))" -PageSize 1)
    Assert-Equal 2 $groups.Count
    Assert-Equal 'IP_SET' $groups[0].typeValue
    Assert-Equal 'VM_CRITERIA' $groups[1].typeValue
    Assert-Equal 2 $fake.Calls.Count
    Assert-True ($fake.Calls[0].Uri -match 'page=1')
    Assert-True ($fake.Calls[1].Uri -match 'page=2')
    Assert-True ($fake.Calls[0].Uri -match 'pageSize=1')
}

Invoke-TestCase -Name '10.6 group summaries and IP Set detail retain their distinct types' -Body {
    $fake = New-FakeVcd106
    $client = New-Vcd106TestClient -Sender $fake.RequestSender
    $groups = @(Get-VcdFirewallGroups -Client $client -GatewayId $fake.GatewayId)
    Assert-Equal 2 $groups.Count
    Assert-Equal 1 $fake.Calls.Count
    $detail = Get-VcdFirewallGroupDetails -Client $client -GroupId $groups[0].id
    Assert-Equal 'IP_SET' $detail.typeValue
    Assert-Equal 3 (@($detail.ipAddresses).Count)
    Assert-Equal '10.60.10.0/28' $detail.ipAddresses[2]
}

Invoke-TestCase -Name '10.6 manual reservations are filtered by network URN, never enumerated unscoped' -Body {
    $fake = New-FakeVcd106
    $results = @(Get-VcdManualIpReservations -Client (New-Vcd106TestClient -Sender $fake.RequestSender) -NetworkId $fake.NetworkId)
    Assert-Equal 1 $results.Count
    Assert-Equal $fake.NetworkId $results[0].networkRef.id
    Assert-Equal '10.60.20.30' $results[0].ipAddresses
    Assert-Equal 1 $fake.Calls.Count
}

Invoke-TestCase -Name '10.6 raw read snapshot includes non-IP Set groups but only fetches supported IP Set detail' -Body {
    $fake = New-FakeVcd106
    $snapshot = Get-VcdReadSnapshot -Client (New-Vcd106TestClient -Sender $fake.RequestSender) -GatewayId $fake.GatewayId -NetworkIds @($fake.NetworkId)
    Assert-Equal 2 (@($snapshot.firewallGroupSummaries).Count)
    Assert-Equal 1 (@($snapshot.ipSetDetails).Count)
    Assert-Equal 1 (@($snapshot.manualIpReservations).Count)
    Assert-Equal 4 $fake.Calls.Count
    $detailRequests = @($fake.Calls | Where-Object {
        $path = ([uri]$_.Uri).AbsolutePath
        $path -match '^/cloudapi/1\.0\.0/firewallGroups/[^/]+$' -and
            $path -notmatch '/firewallGroups/summaries$'
    })
    Assert-Equal 1 $detailRequests.Count
    $detailPath = ([uri]$detailRequests[0].Uri).AbsolutePath
    $requestedGroupId = [uri]::UnescapeDataString($detailPath.Substring($detailPath.LastIndexOf('/') + 1))
    Assert-Equal $snapshot.ipSetDetails[0].id $requestedGroupId
    Assert-Equal 'IP_SET' $snapshot.ipSetDetails[0].typeValue
    Assert-Equal 'VM_CRITERIA' $snapshot.firewallGroupSummaries[1].typeValue
}

Invoke-TestCase -Name '10.6 raw snapshot JSON persists unsupported rule semantics and default rules without loss' -Body {
    $fake = New-FakeVcd106
    $snapshot = Get-VcdReadSnapshot -Client (New-Vcd106TestClient -Sender $fake.RequestSender) -GatewayId $fake.GatewayId -NetworkIds @($fake.NetworkId)
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('vcd106-contract-' + [guid]::NewGuid().ToString('n'))
    try {
        $file = Save-VcdRawSnapshot -Snapshot $snapshot -OutputDirectory $folder
        $roundtrip = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file))
        Assert-Equal 1 (@($roundtrip.firewall.defaultRules).Count)
        Assert-Equal '10.60.20.30' $roundtrip.firewall.userDefinedRules[0].destinationFirewallIpAddresses[0]
        Assert-Equal 'SQL-TCP-1433' $roundtrip.firewall.userDefinedRules[0].applicationPortProfiles[0].name
        Assert-Equal 2 (@($roundtrip.firewallGroupSummaries).Count)
        Assert-Equal 1 (@($roundtrip.manualIpReservations).Count)
    }
    finally { if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder, $true) } }
}

Invoke-TestCase -Name '10.6 full observed-state conversion refuses advanced live policy instead of silently stripping fields' -Body {
    $fake = New-FakeVcd106
    $snapshot = Get-VcdReadSnapshot -Client (New-Vcd106TestClient -Sender $fake.RequestSender) -GatewayId $fake.GatewayId -NetworkIds @($fake.NetworkId)
    Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot } 'Cannot currently project VCD 10.6 firewall rules without loss'
}

Invoke-TestCase -Name '10.6 failed observed import preserves sentinel and saves diagnostic raw snapshot' -Body {
    $fake = New-FakeVcd106
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vcd106-failclosed-' + [guid]::NewGuid().ToString('n'))
    $stateRoot = Join-Path $tmp 'state'
    $observed = Join-Path $stateRoot 'test\edge01\observed'
    try {
        [void][IO.Directory]::CreateDirectory($observed)
        [IO.File]::WriteAllText((Join-Path $observed 'sentinel.txt'),'unmodified')
        $cfg = [pscustomobject]@{
            mode='Live'; apiUrl='https://vcd.example.test:8443'; apiVersion='39.0'
            gatewayId=$fake.GatewayId; networkIds=@($fake.NetworkId)
        }
        Assert-Vcd106Throws {
            Invoke-VcdReadOperation -VcdConfiguration $cfg -OutputDirectory (Join-Path $tmp 'reports') -RequestSender $fake.RequestSender -WriteObserved -StateRoot $stateRoot -Environment 'test' -Scope 'edge01'
        } 'Unsupported live firewall payload must never replace observed state'
        Assert-Equal 'unmodified' ([IO.File]::ReadAllText((Join-Path $observed 'sentinel.txt')))
        Assert-Equal 1 (@(Get-ChildItem -LiteralPath (Join-Path $tmp 'reports') -Filter 'vcd-snapshot-*.json').Count)
        Assert-Equal 8 $fake.Calls.Count
    }
    finally { if ([IO.Directory]::Exists($tmp)) { [IO.Directory]::Delete($tmp, $true) } }
}

Invoke-TestCase -Name '10.6 enabled versus legacy active mismatch fails closed until domain model supports enabled' -Body {
    $snapshot = New-Vcd106LegacyCompatibleSnapshot
    $rule = $snapshot.firewall.userDefinedRules[0]
    $rule.PSObject.Properties.Remove('active')
    $rule | Add-Member -NotePropertyName enabled -NotePropertyValue $true
    Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot }
}

Invoke-TestCase -Name '10.6 protocol, raw ports, application profiles, direct IP and scope features block lossy import' -Body {
    $features = @(
        @{ Field='applicationPortProfiles'; Value=@([pscustomobject]@{ id='profile-1' }) }
        @{ Field='rawPortProtocols'; Value=@([pscustomobject]@{ protocol='TCP'; ports='1433' }) }
        @{ Field='networkContextProfiles'; Value=@([pscustomobject]@{ id='context-1' }) }
        @{ Field='sourceFirewallIpAddresses'; Value=@('10.60.10.11') }
        @{ Field='destinationFirewallIpAddresses'; Value=@('10.60.20.30') }
        @{ Field='appliedTo'; Value=[pscustomobject]@{ id='gateway-1' } }
        @{ Field='direction'; Value='IN_OUT' }
        @{ Field='ipProtocol'; Value='IPV4' }
        @{ Field='futureUnsupportedField'; Value='unknown' }
    )
    foreach ($feature in $features) {
        $snapshot = New-Vcd106LegacyCompatibleSnapshot
        $snapshot.firewall.userDefinedRules[0] | Add-Member -NotePropertyName $feature.Field -NotePropertyValue $feature.Value -Force
        Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot } ("Unsafe field unexpectedly accepted: " + $feature.Field)
    }
}

Invoke-TestCase -Name '10.6 incomplete or unmodelled security group reference cannot be projected' -Body {
    $snapshot = New-Vcd106LegacyCompatibleSnapshot
    $snapshot.firewall.userDefinedRules[0].sourceFirewallGroups = @([pscustomobject]@{id='urn:vcloud:firewallGroup:77777777-7777-4777-8777-777777777777'})
    Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot }
}

Invoke-TestCase -Name '10.6 non-REALIZED firewall status blocks observed import' -Body {
    foreach ($status in @('PENDING','FAILED','UNKNOWN')) {
        $snapshot = New-Vcd106LegacyCompatibleSnapshot
        $snapshot.firewall.status = $status
        Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot } "Status '$status' should not be imported"
    }
}

Invoke-TestCase -Name '10.6 unsupported actions and non-boolean rule flags block observed import' -Body {
    foreach ($mutation in @('BadAction','BadActive','BadLogging')) {
        $snapshot = New-Vcd106LegacyCompatibleSnapshot
        $rule = $snapshot.firewall.userDefinedRules[0]
        switch ($mutation) {
            'BadAction' { $rule.actionValue='PERMIT_ALL_UNKNOWN' }
            'BadActive' { $rule.active='true' }
            'BadLogging' { $rule.logging='false' }
        }
        Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot } $mutation
    }
}

Invoke-TestCase -Name '10.6 reservation ranges and lifecycle fields cannot silently collapse into one IP' -Body {
    foreach ($mutation in @('Range','Expiry')) {
        $snapshot = New-Vcd106LegacyCompatibleSnapshot
        $reservation = $snapshot.manualIpReservations[0]
        if ($mutation -eq 'Range') { $reservation.ipAddresses = '10.1.2.5-10.1.2.9' }
        else { $reservation | Add-Member -NotePropertyName expirationType -NotePropertyValue 'EXPIRATION_DATE' }
        Assert-Vcd106Throws { ConvertTo-VcdObservedDocuments -Snapshot $snapshot } $mutation
    }
}

Invoke-TestCase -Name '10.6 missing userDefinedRules fails before requesting firewall groups or reservations' -Body {
    $calls = [System.Collections.Generic.List[object]]::new()
    $sender = {
        param($r)
        $calls.Add($r)
        return [pscustomobject]@{ status='REALIZED'; systemRules=@(); defaultRules=@() }
    }.GetNewClosure()
    $client = New-Vcd106TestClient -Sender $sender
    Assert-Vcd106Throws { Get-VcdReadSnapshot -Client $client -GatewayId 'urn:vcloud:gateway:x' -NetworkIds @('urn:vcloud:network:y') }
    Assert-Equal 1 $calls.Count
}

Invoke-TestCase -Name '10.6 paging rejects unexpected page index to prevent mixed or repeated pages' -Body {
    $client = New-Vcd106PagedClient -PageSender {
        param($request) [pscustomobject]@{ page=2; pageCount=1; resultTotal=1; values=@([pscustomobject]@{id='one'}) }
    }
    Assert-Vcd106Throws { Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' }
}

Invoke-TestCase -Name '10.6 paging rejects changing pageCount and changing resultTotal' -Body {
    foreach ($change in @('Pages','Total')) {
        $sender = {
            param($request)
            $page = if ($request.Uri -match 'page=2') { 2 } else { 1 }
            $count = if ($change -eq 'Pages' -and $page -eq 2) { 3 } else { 2 }
            $total = if ($change -eq 'Total' -and $page -eq 2) { 3 } else { 2 }
            return [pscustomobject]@{page=$page;pageCount=$count;resultTotal=$total;values=@([pscustomobject]@{id="id-$page"})}
        }.GetNewClosure()
        $client = New-Vcd106PagedClient -PageSender $sender
        Assert-Vcd106Throws { Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' -PageSize 1 } "Invalid changing metadata: $change"
    }
}

Invoke-TestCase -Name '10.6 paging rejects duplicate IDs across pages even when totals match' -Body {
    $client = New-Vcd106PagedClient -PageSender {
        param($r)
        $p = if ($r.Uri -match 'page=2') { 2 } else { 1 }
        return [pscustomobject]@{page=$p;pageSize=1;pageCount=2;resultTotal=2;values=@([pscustomobject]@{id='same-object'})}
    }
    Assert-Vcd106Throws { Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' -PageSize 1 }
}

Invoke-TestCase -Name '10.6 paging rejects resultTotal smaller than items returned' -Body {
    $client = New-Vcd106PagedClient -PageSender {
        param($r) [pscustomobject]@{pageCount=1;resultTotal=1;values=@([pscustomobject]@{id='a'},[pscustomobject]@{id='b'})}
    }
    Assert-Vcd106Throws { Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' }
}

Invoke-TestCase -Name '10.6 paging rejects oversized pageCount before issuing thousands of requests' -Body {
    $count = [pscustomobject]@{ Value=0 }
    $sender = { param($r) $count.Value++; return [pscustomobject]@{pageCount=10001;values=@([pscustomobject]@{id='one'})} }.GetNewClosure()
    Assert-Vcd106Throws { Invoke-VcdPagedRead -Client (New-Vcd106PagedClient -PageSender $sender) -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' }
    Assert-Equal 1 $count.Value
}

Invoke-TestCase -Name '10.6 paging rejects an empty intermediate page' -Body {
    $client = New-Vcd106PagedClient -PageSender {
        param($r) [pscustomobject]@{page=1;pageCount=2;resultTotal=1;values=@()}
    }
    Assert-Vcd106Throws { Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' }
}

Invoke-TestCase -Name '10.6 paging accepts truly empty result without inventing objects' -Body {
    $client = New-Vcd106PagedClient -PageSender {
        param($r) [pscustomobject]@{page=0;pageSize=100;pageCount=0;resultTotal=0;values=@()}
    }
    Assert-Equal 0 (@(Invoke-VcdPagedRead -Client $client -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)').Count)
}

Invoke-TestCase -Name '10.6 paging cancellation prevents subsequent requests' -Body {
    $cancellation = [System.Threading.CancellationTokenSource]::new()
    $calls = [pscustomobject]@{ Value=0 }
    try {
        $sender = {
            param($r)
            $calls.Value++
            $cancellation.Cancel()
            return [pscustomobject]@{page=1;pageCount=2;resultTotal=2;values=@([pscustomobject]@{id='one'})}
        }.GetNewClosure()
        Assert-Vcd106Throws {
            Invoke-VcdPagedRead -Client (New-Vcd106PagedClient -PageSender $sender) -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' -PageSize 1 -CancellationToken $cancellation.Token
        }
        Assert-Equal 1 $calls.Value
    }
    finally { $cancellation.Dispose() }
}

Invoke-TestCase -Name '10.6 API origin refuses embedded secrets, query and fragment' -Body {
    foreach ($url in @('https://user:secret@vcd.example.test:8443','https://vcd.example.test:8443/?a=1','https://vcd.example.test:8443/#x')) {
        Assert-Vcd106Throws { New-VcdApiClient -BaseUri ([uri]$url) -RequestSender { param($r) $null } } "Unsafe origin: $url"
    }
}

Invoke-TestCase -Name '10.6 fake refuses writes, external hosts and undocumented endpoints' -Body {
    $fake = New-FakeVcd106
    Assert-Vcd106Throws { & $fake.RequestSender ([pscustomobject]@{Method='PUT';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/firewallGroups';Headers=@{Accept='application/json;version=39.0'}}) }
    Assert-Vcd106Throws { & $fake.RequestSender ([pscustomobject]@{Method='GET';Uri='https://other.example.test/api/versions';Headers=@{Accept='application/*+xml'}}) }
    Assert-Vcd106Throws { & $fake.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/unknown';Headers=@{Accept='application/json;version=39.0'}}) }
    Assert-Equal 1 $fake.Calls.Count 'Only the attempted local, read-only unknown route is recorded'
}

Invoke-TestCase -Name '10.6 read-only HTTP transport propagates 503 without exposing server body' -Body {
    . (Join-Path $ProjectRoot 'tests\Mocks\FakeHttpHandler.ps1')
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -Force
    $fake = [VcdMockHttpHandler]::new()
    $fake.Mode = 'Error'
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        $message = ''
        try { $null = Get-VcdApiVersions -Client (New-Vcd106TestClient -Sender $transport.RequestSender) }
        catch { $message = $_.Exception.Message }
        Assert-True ($message -match '503') '503 must surface as an error'
        Assert-True (-not $message.Contains('sensitive server data')) 'Server body must not leak into diagnostic logs'
        Assert-Equal 'GET' $fake.LastMethod
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name '10.6 snapshot refuses unsupported missing firewall collection and incomplete paging' -Body {
    $count = [pscustomobject]@{Value=0}
    $sender = {
        param($r)
        $count.Value++
        if ($r.Uri -match 'firewall/rules$') { return [pscustomobject]@{status='REALIZED';userDefinedRules=@()} }
        return [pscustomobject]@{page=1;pageCount=1;resultTotal=2;values=@([pscustomobject]@{id='one';typeValue='IP_SET'})}
    }.GetNewClosure()
    Assert-Vcd106Throws { Get-VcdReadSnapshot -Client (New-Vcd106TestClient -Sender $sender) -GatewayId 'urn:vcloud:gateway:valid' -NetworkIds @() }
    Assert-Equal 2 $count.Value
}

. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcd106HttpHandler.ps1')

Invoke-TestCase -Name '10.6 HTTP adapter rejects 401 403 429 500 503 504 without leaking response bodies' -Body {
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -Force
    foreach ($status in @(401,403,429,500,503,504)) {
        $fake = [Vcd106ResponseHandler]::new()
        $fake.StatusCode = $status
        $fake.Payload = 'secret internal diagnostic content'
        $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
        try {
            Connect-VcdHttpTransport -Transport $transport -BearerToken 'synthetic-test-token'
            $failure = ''
            try { $null = & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current';Headers=@{Accept='application/json;version=39.0'}}) }
            catch { $failure = $_.Exception.Message }
            Assert-True ($failure.Contains([string]$status)) "Expected error $status"
            Assert-True (-not $failure.Contains('secret internal diagnostic')) 'Response body must not be logged'
            Assert-Equal 1 $fake.Count 'No hidden retries on error response'
        }
        finally { Close-VcdHttpTransport -Transport $transport }
    }
}

Invoke-TestCase -Name '10.6 HTTP adapter refuses redirect and does not request redirected host' -Body {
    $fake = [Vcd106ResponseHandler]::new()
    $fake.StatusCode = 302
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        Connect-VcdHttpTransport -Transport $transport -BearerToken 'synthetic-test-token'
        Assert-Vcd106Throws { & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current';Headers=@{Accept='application/json;version=39.0'}}) }
        Assert-Equal 1 $fake.Count
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name '10.6 HTTP adapter rejects malformed and empty JSON payloads' -Body {
    foreach ($payload in @('this is not JSON','')) {
        $fake = [Vcd106ResponseHandler]::new()
        $fake.Payload = $payload
        $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
        try {
            Connect-VcdHttpTransport -Transport $transport -BearerToken 'synthetic-test-token'
            Assert-Vcd106Throws { & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current';Headers=@{Accept='application/json;version=39.0'}}) }
            Assert-Equal 1 $fake.Count
        }
        finally { Close-VcdHttpTransport -Transport $transport }
    }
}

Invoke-TestCase -Name '10.6 login rejects a successful response that omits access-token header' -Body {
    $fake = [Vcd106ResponseHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        $pw = ConvertTo-SecureString 'synthetic-only-password' -AsPlainText -Force
        $credential = [pscredential]::new('fixture-user@synthetic', $pw)
        Assert-Vcd106Throws { Connect-VcdHttpTransport -Transport $transport -Credential $credential -ApiVersion '39.0' }
        Assert-Equal 'POST' $fake.LastMethod
        Assert-Equal '/cloudapi/1.0.0/sessions' $fake.LastPath
        Assert-Equal 'Basic' $fake.LastAuthScheme
        Assert-Equal '' $transport.InternalState.Token
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name '10.6 bearer auth stays on the configured host and preserves Accept version' -Body {
    $fake = [Vcd106ResponseHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        Connect-VcdHttpTransport -Transport $transport -BearerToken 'synthetic-token' -ApiVersion '39.0'
        $json = & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current';Headers=@{Accept='application/json;version=39.0'}})
        Assert-True ($json.id -like 'urn:vcloud:session:*')
        Assert-Equal 'Bearer' $fake.LastAuthScheme
        Assert-True ($fake.LastAccept -match 'version=39.0')
        Assert-Vcd106Throws { & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://other.example.test/cloudapi/1.0.0/sessions/current';Headers=@{Accept='application/json;version=39.0'}}) }
        Assert-Equal 1 $fake.Count
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}


Invoke-TestCase -Name '10.6 paging validates negative malformed and non-numeric metadata' -Body {
    foreach ($pageData in @(
        [pscustomobject]@{pageCount=-1;resultTotal=0;values=@()},
        [pscustomobject]@{pageCount='NaN';resultTotal=1;values=@([pscustomobject]@{id='a'})},
        [pscustomobject]@{pageCount=1;resultTotal=-3;values=@([pscustomobject]@{id='a'})},
        [pscustomobject]@{pageCount=1;page='two';resultTotal=1;values=@([pscustomobject]@{id='a'})}
    )) {
        $sender = { param($r) return $pageData }.GetNewClosure()
        Assert-Vcd106Throws { Invoke-VcdPagedRead -Client (New-Vcd106PagedClient -PageSender $sender) -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' }
    }
}

Invoke-TestCase -Name '10.6 paging rejects impossible pageSize and overfilled result pages' -Body {
    foreach ($mode in @('BadReportedSize','TooManyResults')) {
        $sender = {
            param($r)
            if ($mode -eq 'BadReportedSize') {
                return [pscustomobject]@{page=1;pageSize=128;pageCount=1;resultTotal=1;values=@([pscustomobject]@{id='a'})}
            }
            return [pscustomobject]@{page=1;pageSize=1;pageCount=1;resultTotal=2;values=@([pscustomobject]@{id='a'},[pscustomobject]@{id='b'})}
        }.GetNewClosure()
        Assert-Vcd106Throws { Invoke-VcdPagedRead -Client (New-Vcd106PagedClient -PageSender $sender) -ResourcePath '/cloudapi/1.0.0/firewallGroups/summaries' -Filter '(x==y)' -PageSize 1 }
    }
}

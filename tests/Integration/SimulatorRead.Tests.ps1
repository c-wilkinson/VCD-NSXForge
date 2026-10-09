Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorServer.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force

Invoke-TestCase -Name 'Existing VCD read pipeline consumes synthetic simulator endpoints without network' -Body {
    $data = Import-SimulatorTopology -Path (Join-Path $ProjectRoot 'simulator\topology.json')
    $gateway = @($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
    $routeCommand = Get-Command Invoke-SimulatorRoute
    $calls = [System.Collections.Generic.List[object]]::new()
    $sender = {
        param($request)
        $calls.Add($request)
        $uri = [uri]$request.Uri
        $query = @{}
        if ($uri.Query) {
            foreach ($item in $uri.Query.TrimStart('?').Split('&')) {
                $parts = $item.Split('=',2)
                $query[[uri]::UnescapeDataString($parts[0])] = if ($parts.Count -gt 1) { [uri]::UnescapeDataString($parts[1]) } else { '' }
            }
        }
        $response = & $routeCommand -Dataset $data -Method $request.Method -Path $uri.AbsolutePath -Query $query -Authorization 'Bearer simulator-read-only'
        if ($response.StatusCode -ne 200) { throw "Simulated HTTP $($response.StatusCode)" }
        if ($response.Body -is [string]) { return $response.Body }
        return ($response.Body | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json)
    }.GetNewClosure()
    $vcd = (Read-AppConfiguration -ApplicationRoot $ProjectRoot).vcd
    if ($vcd.PSObject.Properties.Name -contains 'mode') { $vcd.mode = 'Simulator' }
    else { $vcd | Add-Member -NotePropertyName mode -NotePropertyValue Simulator }
    $vcd.apiUrl = 'http://127.0.0.1:8765'
    $vcd.gatewayId = $gateway.gatewayId
    $vcd.networkIds = @($gateway.networkId)
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vcd-simread-' + [guid]::NewGuid().ToString('n'))
    try {
        $output = Invoke-VcdReadOperation -VcdConfiguration $vcd -OutputDirectory $scratch -RequestSender $sender -WriteObserved -StateRoot (Join-Path $scratch 'state') -Environment demo -Scope simulator-domainb-t1
        Assert-True $output.ObservedImported
        Assert-True ([IO.File]::Exists((Join-Path $scratch 'state\demo\simulator-domainb-t1\observed\firewall-rules.json')))
        Assert-True $output.Connected
        Assert-Equal 1 $output.FirewallRuleCount
        Assert-Equal 1 $output.IpSetCount
        Assert-Equal 1 $output.ReservationCount
        Assert-Equal 6 $calls.Count
        Assert-True ([IO.File]::Exists($output.SnapshotPath))
        $content = [IO.File]::ReadAllText($output.SnapshotPath) | ConvertFrom-Json
        Assert-Equal 'DomainB-T1-Systems' $content.ipSetDetails[0].name
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) } }
}

Invoke-TestCase -Name 'Simulator read path rejects real credentials or bearer-token inputs' -Body {
    $vcd = (Read-AppConfiguration -ApplicationRoot $ProjectRoot).vcd
    if ($vcd.PSObject.Properties.Name -contains 'mode') { $vcd.mode = 'Simulator' }
    else { $vcd | Add-Member -NotePropertyName mode -NotePropertyValue Simulator }
    $vcd.apiUrl = 'http://127.0.0.1:8765'
    $vcd.gatewayId = 'urn:vcloud:gateway:11111111-1111-4111-8111-111111111111'
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $vcd -OutputDirectory ([IO.Path]::GetTempPath()) -BearerToken 'real-secret' }
    $cred = [pscredential]::new('real-user', (ConvertTo-SecureString 'real-secret' -AsPlainText -Force))
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $vcd -OutputDirectory ([IO.Path]::GetTempPath()) -Credential $cred }
    $vcd.apiUrl = 'http://not-loopback.example.test'
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $vcd -OutputDirectory ([IO.Path]::GetTempPath()) }
}

Invoke-TestCase -Name 'Loopback HTTP transport is opt-in and cannot point to external host' -Body {
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdApi.psm1') -Force
    Assert-Throws { New-VcdHttpTransport -BaseUri ([uri]'http://127.0.0.1:8765') }
    Assert-Throws { New-VcdHttpTransport -BaseUri ([uri]'http://example.test:8765') -AllowLoopbackHttp }
    Assert-Throws { New-VcdApiClient -BaseUri ([uri]'http://example.test:8765') -RequestSender {param($req) $null} -AllowLoopbackHttp }
    $transport = New-VcdHttpTransport -BaseUri ([uri]'http://127.0.0.1:8765') -AllowLoopbackHttp
    try {
        $fakeCredential = [pscredential]::new('simulator@local',(ConvertTo-SecureString 'simulator-only' -AsPlainText -Force))
        Assert-Throws { Connect-VcdHttpTransport -Transport $transport -Credential $fakeCredential }
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='http://example.test:8765/api/versions';Headers=@{}}) }
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{Method='POST';Uri='http://127.0.0.1:8765/cloudapi/1.0.0/firewallGroups';Headers=@{}}) }
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

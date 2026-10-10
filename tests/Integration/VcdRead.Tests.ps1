Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\State\StateRepository.psm1') -Force
. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcdRead.ps1')

function New-TestVcdConfiguration {
    $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
    if ($cfg.vcd.PSObject.Properties.Name -contains 'mode') { $cfg.vcd.mode='Live' }
    $cfg.vcd.apiUrl = 'https://vcd.example.test:8443'
    $cfg.vcd.gatewayId = 'urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
    $cfg.vcd.networkIds = @('urn:vcloud:network:44444444-4444-4444-8444-444444444444')
    return $cfg.vcd
}

Invoke-TestCase -Name 'Read-only VCD snapshot uses versions session firewall groups details and reservations' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $config = New-TestVcdConfiguration
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $out = Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory $scratch -RequestSender $fake.RequestSender
        Assert-True $out.Connected
        Assert-Equal '39.0' $out.ApiVersion
        Assert-Equal 1 $out.FirewallRuleCount
        Assert-Equal 1 $out.IpSetCount
        Assert-Equal 1 $out.ReservationCount
        Assert-Equal 6 $fake.Calls.Count
        Assert-Equal 6 (@($fake.Calls | Where-Object {$_.Method -ceq 'GET'}).Count)
        Assert-True ([IO.File]::Exists($out.SnapshotPath))
        $snapshot = [IO.File]::ReadAllText($out.SnapshotPath) | ConvertFrom-Json
        Assert-Equal 'App Servers' $snapshot.ipSetDetails[0].name
        Assert-Equal '10.1.2.8' $snapshot.manualIpReservations[0].ipAddresses
        Assert-Equal 'https://vcd.example.test:8443/api/versions' $fake.Calls[0].Uri
    }
    finally { if ([IO.Directory]::Exists($scratch)) {[IO.Directory]::Delete($scratch,$true)} }
}

Invoke-TestCase -Name 'VCD connection-only operation does not retrieve or save network snapshot' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $result = Invoke-VcdReadOperation -VcdConfiguration (New-TestVcdConfiguration) -OutputDirectory $scratch -RequestSender $fake.RequestSender -ConnectionOnly
    Assert-Equal '' $result.SnapshotPath
    Assert-True $result.Connected
    Assert-Equal '39.0' $result.ApiVersion
    Assert-True ($result.PSObject.Properties.Name -cnotcontains 'FirewallRuleCount') 'Connection check is not a snapshot and must not invent resource counts'
    Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadSummary.psm1') -ErrorAction Stop
    $summary = New-VcdReadCompletionSummary -Result $result -ConnectionOnly
    Assert-True ($summary.Message -match 'Connected successfully') 'Real connection-only result must format without missing-count errors'
    Assert-Equal 2 $fake.Calls.Count
    Assert-True (-not [IO.Directory]::Exists($scratch))
}

Invoke-TestCase -Name 'Snapshot can map supported VCD subset and replace observed documents without touching desired' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $result = Invoke-VcdReadOperation -VcdConfiguration (New-TestVcdConfiguration) -OutputDirectory (Join-Path $scratch 'reports') -RequestSender $fake.RequestSender -WriteObserved -StateRoot (Join-Path $scratch 'state') -Environment 'test' -Scope 'edge01'
        Assert-True $result.ObservedImported
        $state = Read-NetworkStateView -StateRoot (Join-Path $scratch 'state') -Environment test -Scope edge01 -View observed
        Assert-True $state.Available
        Assert-Equal 1 $state.Documents.ipSets.items.Count
        Assert-Equal 'vcd-22222222-2222-4222-8222-222222222222' $state.Documents.edgeFirewallRules.items[0].sourceIpSets[0]
        Assert-Equal '10.1.2.8' $state.Documents.manualIpReservations.items[0].address
        $desired = Read-NetworkStateView -StateRoot (Join-Path $scratch 'state') -Environment test -Scope edge01 -View desired
        Assert-True (-not $desired.Available)
    }
    finally { if ([IO.Directory]::Exists($scratch)) {[IO.Directory]::Delete($scratch,$true)} }
}

Invoke-TestCase -Name 'Unsupported VCD rule keeps existing observed state untouched but preserves raw snapshot' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3') -UnsupportedFirewall
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $stateRoot = Join-Path $scratch 'state'
        $original = [IO.Path]::Combine($stateRoot,'test','edge01','observed')
        [void][IO.Directory]::CreateDirectory($original)
        [IO.File]::WriteAllText((Join-Path $original 'sentinel.txt'), 'original')
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-TestVcdConfiguration) -OutputDirectory (Join-Path $scratch 'reports') -RequestSender $fake.RequestSender -WriteObserved -StateRoot $stateRoot -Environment test -Scope edge01 } 'Unsupported firewall feature must not be lost'
        Assert-Equal 'original' ([IO.File]::ReadAllText((Join-Path $original 'sentinel.txt')))
        Assert-Equal 1 (@(Get-ChildItem (Join-Path $scratch 'reports') -Filter 'vcd-snapshot-*.json').Count)
    }
    finally { if ([IO.Directory]::Exists($scratch)) {[IO.Directory]::Delete($scratch,$true)} }
}

Invoke-TestCase -Name 'Simulated VCD 503 and cancelled reads leave observed state unchanged' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3') -HttpFailure
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-TestVcdConfiguration) -OutputDirectory $scratch -RequestSender $fake.RequestSender }
        Assert-True (-not [IO.Directory]::Exists($scratch))
        $cts = [System.Threading.CancellationTokenSource]::new()
        $cts.Cancel()
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-TestVcdConfiguration) -OutputDirectory $scratch -RequestSender $fake.RequestSender -CancellationToken $cts.Token }
        $cts.Dispose()
    }
    finally { if ([IO.Directory]::Exists($scratch)) {[IO.Directory]::Delete($scratch,$true)} }
}

Invoke-TestCase -Name 'Observed import refuses unqueried reservation networks without making a request' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $config = New-TestVcdConfiguration
    $config.networkIds = @()
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory (Join-Path $scratch 'reports') -RequestSender $fake.RequestSender -WriteObserved -StateRoot (Join-Path $scratch 'state') -Environment demo -Scope edge01 }
    Assert-Equal 0 $fake.Calls.Count
    Assert-True (-not [IO.Directory]::Exists($scratch))
}

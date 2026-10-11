Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -ErrorAction Stop
. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcdSessionLifecycleHandler.ps1')

function New-LifecycleTestConfig {
    $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
    $vcd = $cfg.vcd
    $vcd.mode = 'Live'
    $vcd.apiUrl = 'https://vcd.example.test:8443'
    $vcd.gatewayId = 'urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
    $vcd.networkIds = @('urn:vcloud:network:44444444-4444-4444-8444-444444444444')
    return $vcd
}
function New-LifecycleTestCredential {
    return [pscredential]::new('engineer@tenant', (ConvertTo-SecureString 'test-only-credential' -AsPlainText -Force))
}

# A credential-backed connection exercises the actual Invoke-VcdReadOperation
# switch binding. Passing a Boolean as a separate positional argument to the
# ProviderLogin switch fails before the fake handler receives its login POST.
Invoke-TestCase -Name 'Credential read uses tenant login when provider mode is false' -Body {
    $fake = [VcdSessionLifecycleHandler]::new()
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $out = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) -ConnectionOnly
        Assert-True $out.Connected
        Assert-Equal 1 $fake.LoginCount
        Assert-Equal 1 @($fake.Requests | Where-Object { $_ -ceq 'POST /cloudapi/1.0.0/sessions' }).Count
        Assert-Equal 0 $fake.FirewallReadCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Credential read uses provider login only with explicit scope and attestation' -Body {
    $fake = [VcdSessionLifecycleHandler]::new()
    $fake.AttestProviderSession = $true
    $configuration = New-LifecycleTestConfig
    $configuration.loginScope = 'Provider'
    $configuration.tenantContextOrgId = 'urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $out = Invoke-VcdReadOperation -VcdConfiguration $configuration -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) -ConnectionOnly
        Assert-True $out.Connected
        Assert-Equal 1 $fake.LoginCount
        Assert-Equal 1 @($fake.Requests | Where-Object { $_ -ceq 'POST /cloudapi/1.0.0/sessions/provider' }).Count
        Assert-Equal 0 @($fake.Requests | Where-Object { $_ -ceq 'POST /cloudapi/1.0.0/sessions' }).Count
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name '401 on page N restarts entire snapshot under a reverified identity and publishes once' -Body {
    $fake = [VcdSessionLifecycleHandler]::new()
    $fake.Mode = 'ExpireOnce'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $out = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory (Join-Path $root 'reports') -HttpHandler $fake -Credential (New-LifecycleTestCredential) -WritePolicyObserved -StateRoot (Join-Path $root 'state') -Environment lab -Scope edge01
        Assert-True $out.Connected
        Assert-True ([IO.File]::Exists($out.SnapshotPath))
        Assert-Equal 2 $fake.LoginCount
        Assert-Equal 2 $fake.FirewallReadCount
        Assert-Equal 2 $fake.PageReadCount
        Assert-Equal 1 @(Get-ChildItem (Join-Path $root 'reports') -File).Count
        Assert-True $out.PolicyImported
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name '401 with borrowed bearer token never performs login or retries and leaves state unchanged' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'AlwaysUnauthorized'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $failure = ''
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -BearerToken 'opaque-test-token' }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'Sign in again')
        Assert-Equal 0 $fake.LoginCount
        Assert-Equal 1 $fake.PageReadCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name '403 forbids access and never triggers reauthentication or partial state writes' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'Forbidden'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $failure = ''
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'access forbidden')
        Assert-Equal 1 $fake.LoginCount
        Assert-Equal 1 $fake.ForbiddenCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Renewal denied after a partial read never publishes a snapshot or leaks credentials' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'RenewalDenied'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $failure = ''
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) }
        catch { $failure = $_.Exception.Message }
        Assert-Equal 2 $fake.LoginCount
        Assert-True (-not [string]::IsNullOrWhiteSpace($failure))
        Assert-True (-not $failure.Contains('test-only-credential'))
        Assert-True (-not $failure.Contains('do-not-echo'))
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Identity switching at renewal blocks cross-tenant snapshot completion' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'ScopeChanges'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $failure = ''
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'identity denied')
        Assert-Equal 2 $fake.LoginCount
        Assert-Equal 1 $fake.FirewallReadCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Cancellation during page N prevents token refresh and partial publication' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'Cancelled'
    $cts = [System.Threading.CancellationTokenSource]::new()
    $fake.CancelAtPage = $cts
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $cancelled = $false
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) -CancellationToken $cts.Token }
        catch [System.OperationCanceledException] { $cancelled = $true }
        Assert-True $cancelled 'Cancellation during an HTTP 401 must propagate as cancellation'
        Assert-Equal 1 $fake.LoginCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { $cts.Dispose(); if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Transport tracks forbidden state and invalidates token without leaking it' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'Forbidden'
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        Connect-VcdHttpTransport -Transport $transport -BearerToken 'opaque-test-token'
        Assert-Throws { $null = & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/manualIpReservations';Headers=@{} }) }
        $health = Get-VcdTransportSessionStatus -Transport $transport
        Assert-Equal 'Revoked/Forbidden' $health.Status
        Assert-True (-not $health.CanUseToken)
        Assert-True ([string]::IsNullOrEmpty($transport.InternalState.Token))
        Assert-Equal 1 $fake.ForbiddenCount
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name 'Session expiry from authenticated session metadata prevents stale token requests' -Body {
    $fake = [VcdSessionLifecycleHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        Connect-VcdHttpTransport -Transport $transport -BearerToken 'opaque-test-token'
        Set-VcdTransportSessionLifetime -Transport $transport -Session ([pscustomobject]@{ expirationDate='2026-01-01T00:00:00Z' })
        $health = Get-VcdTransportSessionStatus -Transport $transport
        Assert-Equal 'Expired' $health.Status
        Assert-Throws { $null = & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current';Headers=@{} }) }
        Assert-Equal 0 $fake.Requests.Count # bearer mode makes no HTTP login; expired token makes no GET
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name 'Repeated 401 is bounded to one credential-backed renewal, with no partial output' -Body {
    $fake = [VcdSessionLifecycleHandler]::new(); $fake.Mode = 'AlwaysUnauthorized'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $failure = ''
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'Sign in again')
        Assert-Equal 2 $fake.LoginCount
        Assert-Equal 2 $fake.FirewallReadCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Near-expiry sessions proactively reauthenticate before starting paginated reads' -Body {
    $fake = [VcdSessionLifecycleHandler]::new()
    $fake.SessionExpiry = [datetime]::UtcNow.AddSeconds(25).ToString('o')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-lifecycle-' + [guid]::NewGuid().ToString('n'))
    try {
        $failure = ''
        try { $null = Invoke-VcdReadOperation -VcdConfiguration (New-LifecycleTestConfig) -OutputDirectory $root -HttpHandler $fake -Credential (New-LifecycleTestCredential) }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'Sign in again')
        Assert-Equal 2 $fake.LoginCount
        Assert-Equal 0 $fake.FirewallReadCount
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Transport session gate coordinates login and GET on the same state object' -Body {
    $fake = [VcdSessionLifecycleHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        Assert-True ($transport.InternalState.Gate -is [object])
        Connect-VcdHttpTransport -Transport $transport -Credential (New-LifecycleTestCredential)
        $first = Get-VcdTransportSessionStatus -Transport $transport
        Assert-Equal 'Valid' $first.Status
        $null = & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current';Headers=@{} })
        Assert-Equal 1 $fake.LoginCount
        Assert-Equal 2 $fake.Requests.Count
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

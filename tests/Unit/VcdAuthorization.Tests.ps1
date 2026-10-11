Import-Module (Join-Path $ProjectRoot 'src\Domain\Access\VcdAuthorization.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force
. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcdRead.ps1')
. (Join-Path $ProjectRoot 'tests\Mocks\FakeHttpHandler.ps1')

function New-SecurityTestSession {
    [pscustomobject]@{ id='urn:vcloud:session:test'; user='engineer@tenant'; orgRef=[pscustomobject]@{id='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'} }
}

function New-SecurityVcdConfiguration {
    $cfg = (Read-AppConfiguration -ApplicationRoot $ProjectRoot).vcd
    $cfg.mode = 'Live'; $cfg.apiUrl = 'https://vcd.example.test:8443'
    $cfg.gatewayId = 'urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
    $cfg.networkIds = @('urn:vcloud:network:44444444-4444-4444-8444-444444444444')
    $cfg.loginScope = 'Tenant'; $cfg.tenantContextOrgId = ''
    return $cfg
}

Invoke-TestCase -Name 'Live identity is verified from server session, not configured username or simulator actor' -Body {
    $identity = New-VcdLiveIdentity -Session (New-SecurityTestSession)
    Assert-Equal 'engineer@tenant' $identity.User
    Assert-True (-not $identity.IsProvider)
    Assert-True (-not ($identity.PSObject.Properties.Name -contains 'Token'))
    Assert-Throws { New-VcdLiveIdentity -Session ([pscustomobject]@{id='urn:vcloud:session:x';user='engineer'}) }
    Assert-Throws { New-VcdLiveIdentity -Session (New-SecurityTestSession) -TenantContextOrgId 'urn:vcloud:org:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
}

Invoke-TestCase -Name 'Provider privilege needs attested session flag and explicit tenant' -Body {
    $session = New-SecurityTestSession
    Assert-Throws { New-VcdLiveIdentity -Session $session -LoginScope Provider -TenantContextOrgId 'urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
    $session | Add-Member -NotePropertyName isProvider -NotePropertyValue $true
    Assert-Throws { New-VcdLiveIdentity -Session $session -LoginScope Provider }
    $provider = New-VcdLiveIdentity -Session $session -LoginScope Provider -TenantContextOrgId 'urn:vcloud:org:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True $provider.IsProvider
}

Invoke-TestCase -Name 'Headless live authorisation blocks writes and mismatched or unproved ownership' -Body {
    $identity = New-VcdLiveIdentity -Session (New-SecurityTestSession)
    $id = 'urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
    $allowed = [pscustomobject]@{id=$id;orgRef=[pscustomobject]@{id=$identity.TargetOrgId}}
    Confirm-VcdLiveAuthorization -Identity $identity -Action Read -ResourceId $id -Resource $allowed
    Assert-Throws { Confirm-VcdLiveAuthorization -Identity $identity -Action Apply }
    Assert-Throws { Confirm-VcdLiveAuthorization -Identity $identity -Action Approve }
    Assert-Throws { Confirm-VcdLiveAuthorization -Identity $identity -Action Read -ResourceId 'other' -Resource $allowed }
    Assert-Throws { Confirm-VcdLiveAuthorization -Identity $identity -Action Read -ResourceId $id -Resource ([pscustomobject]@{id=$id}) }
    Assert-Throws { Confirm-VcdLiveAuthorization -Identity $identity -Action Read -ResourceId $id -Resource ([pscustomobject]@{id=$id;orgRef=[pscustomobject]@{id='urn:vcloud:org:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}}) }
}

Invoke-TestCase -Name 'Wrong-tenant gateway is rejected before firewall read or report writes' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $original = $fake.RequestSender
    $sender = {
        param($request)
        if (([uri]$request.Uri).AbsolutePath -like '/cloudapi/1.0.0/edgeGateways/*') {
            return [pscustomobject]@{id='urn:vcloud:gateway:55555555-5555-4555-8555-555555555555';orgRef=[pscustomobject]@{id='urn:vcloud:org:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}}
        }
        & $original $request
    }.GetNewClosure()
    $root = Join-Path ([IO.Path]::GetTempPath()) ('issue8-' + [guid]::NewGuid().ToString('n'))
    try {
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-SecurityVcdConfiguration) -OutputDirectory (Join-Path $root 'reports') -RequestSender $sender -WriteObserved -StateRoot (Join-Path $root 'state') -Environment lab -Scope edge01 }
        Assert-True (-not [IO.Directory]::Exists($root))
        Assert-True (-not (@($fake.Calls | Where-Object { ([uri]$_.Uri).AbsolutePath -like '*/firewall/rules' }).Count -gt 0))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Wrong-tenant network is rejected before firewall data and state import' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $original = $fake.RequestSender
    $sender = {
        param($request)
        if (([uri]$request.Uri).AbsolutePath -like '/cloudapi/1.0.0/orgVdcNetworks/*') {
            return [pscustomobject]@{id='urn:vcloud:network:44444444-4444-4444-8444-444444444444';orgRef=[pscustomobject]@{id='urn:vcloud:org:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}}
        }
        & $original $request
    }.GetNewClosure()
    $root = Join-Path ([IO.Path]::GetTempPath()) ('issue8-' + [guid]::NewGuid().ToString('n'))
    try {
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-SecurityVcdConfiguration) -OutputDirectory (Join-Path $root 'reports') -RequestSender $sender -WritePolicyObserved -StateRoot (Join-Path $root 'state') -Environment lab -Scope edge01 }
        Assert-True (-not [IO.Directory]::Exists($root))
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Untrusted snapshot containing credential material is never exported' -Body {
    Assert-Throws { Confirm-VcdArtifactContainsNoSecrets -Value ([pscustomobject]@{firewall=[pscustomobject]@{accessToken='never-export-123'}}) }
    Assert-Throws { Confirm-VcdArtifactContainsNoSecrets -Value ([pscustomobject]@{description='Authorization: Bearer syntheticsecret123'}) }
    Confirm-VcdArtifactContainsNoSecrets -Value ([pscustomobject]@{firewall=[pscustomobject]@{description='SQL traffic';order=1}})
}

Invoke-TestCase -Name 'HTTP 401 and 403 invalidate tokens and cannot leak response body' -Body {
    foreach ($mode in @('Unauthorized','Forbidden')) {
        $fake = [VcdMockHttpHandler]::new()
        $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test') -Handler $fake
        try {
            Connect-VcdHttpTransport -Transport $transport -BearerToken 'secret-issue8-token'
            $fake.Mode = $mode
            $failure = ''
            try { $null = & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test/cloudapi/1.0.0/sessions/current';Headers=@{}}) }
            catch { $failure = $_.Exception.Message }
            Assert-True ($failure -match 'HTTP (401|403)')
            Assert-True (-not $failure.Contains('confidential-never-echo'))
            Assert-Equal '' $transport.InternalState.Token
        }
        finally { Close-VcdHttpTransport -Transport $transport }
    }
}

Invoke-TestCase -Name 'HTTP caller cannot inject Authorization or tenant headers' -Body {
    $fake = [VcdMockHttpHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test') -Handler $fake
    try {
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test/api/versions';Headers=@{Authorization='Bearer injected-secret'}}) }
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{Method='GET';Uri='https://vcd.example.test/api/versions';Headers=@{'X-VMWARE-VCLOUD-TENANT-CONTEXT'='another-tenant'}}) }
        Assert-Equal 0 $fake.Count
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name 'Logger redacts common bearer, basic and password patterns and omits secret properties' -Body {
    $logger = [pscustomobject]@{
        MinimumLevel='INFO'; Queue=[System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Signal=[System.Threading.ManualResetEventSlim]::new($false)
    }
    try {
        Write-AppLog -Logger $logger -Component Test -Message 'Authorization: Bearer super-secret-123 password=hunter2' -Properties @{token='private-xyz';nested=@{authorization='private-other';description='Basic abc123xyz'}}
        $record = $null
        Assert-True ($logger.Queue.TryDequeue([ref]$record))
        $serialized = $record | ConvertTo-Json -Depth 10 -Compress
        foreach ($secret in @('super-secret-123','hunter2','private-xyz','private-other','abc123xyz')) {
            Assert-True (-not $serialized.Contains($secret)) "Leaked test secret: $secret"
        }
        Assert-True ($serialized.Contains('[REDACTED]'))
    }
    finally { $logger.Signal.Dispose() }
}

Invoke-TestCase -Name 'Configuration refuses even optional secret fields in distributable JSON' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('issue8-config-' + [guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'config'))
        $config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config\application.json') -Raw | ConvertFrom-Json
        $config.vcd | Add-Member -NotePropertyName accessToken -NotePropertyValue 'hardcoded-secret-123'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $scratch 'config\application.json') -Encoding UTF8
        Assert-Throws { Read-AppConfiguration -ApplicationRoot $scratch }
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) } }
}

Invoke-TestCase -Name 'Untrusted server exception body is not exposed by the read operation' -Body {
    $origin = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $original = $origin.RequestSender
    $sender = {
        param($request)
        if (([uri]$request.Uri).AbsolutePath -like '*/firewall/rules') { throw 'Bearer supersecret123 HTTP backend failure' }
        & $original $request
    }.GetNewClosure()
    $msg = ''
    try {
        $null = Invoke-VcdReadOperation -VcdConfiguration (New-SecurityVcdConfiguration) -OutputDirectory ([IO.Path]::GetTempPath()) -RequestSender $sender
    }
    catch { $msg = $_.Exception.Message }
    Assert-True ($msg -match 'VCD operation failed')
    Assert-True (-not $msg.Contains('supersecret123'))
}

Invoke-TestCase -Name 'Cancelled authentication attempt does not create output or access VCD' -Body {
    $fake = New-FakeVcdReadSender -FixtureRoot (Join-Path $ProjectRoot 'tests\Fixtures\Phase3')
    $cts = [System.Threading.CancellationTokenSource]::new()
    $path = Join-Path ([IO.Path]::GetTempPath()) ('issue8-cancel-' + [guid]::NewGuid().ToString('n'))
    try {
        $cts.Cancel()
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-SecurityVcdConfiguration) -OutputDirectory $path -RequestSender $fake.RequestSender -CancellationToken $cts.Token }
        Assert-Equal 0 $fake.Calls.Count
        Assert-True (-not [IO.Directory]::Exists($path))
    }
    finally { $cts.Dispose() }
}

Invoke-TestCase -Name 'Simulator transport cannot accidentally receive a real bearer token' -Body {
    $transport = New-VcdHttpTransport -BaseUri ([uri]'http://127.0.0.1:8765') -AllowLoopbackHttp
    try {
        Assert-Throws { Connect-VcdHttpTransport -Transport $transport -BearerToken 'real-token-must-not-be-sent' }
        Assert-Equal '' $transport.InternalState.Token
        Connect-VcdHttpTransport -Transport $transport -BearerToken 'simulator-read-only'
        Assert-Equal 'simulator-read-only' $transport.InternalState.Token
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

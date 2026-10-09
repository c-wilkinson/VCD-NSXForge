Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdApi.psm1') -Force

Invoke-TestCase -Name 'API constructor rejects HTTP, extra path and missing sender' -Body {
    $sender = { param($request) $null }
    Assert-Throws { New-VcdApiClient -BaseUri 'http://vcd.example.test' -RequestSender $sender } 'Plain HTTP must fail'
    Assert-Throws { New-VcdApiClient -BaseUri 'https://vcd.example.test/tenant' -RequestSender $sender } 'API origin only'
    Assert-Throws { New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender $null } 'Transport must be injected (without an interactive mandatory-parameter prompt)'
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test:8443' -RequestSender $sender
    Assert-Equal '39.0' $client.ApiVersion
}

Invoke-TestCase -Name 'Mocked API discovers supported VCD versions from XML' -Body {
    $calls = [System.Collections.Generic.List[object]]::new()
    $sender = {
        param($request)
        $calls.Add($request)
        '<Versions><VersionInfo><Version>38.1</Version></VersionInfo><VersionInfo><Version>39.0</Version></VersionInfo></Versions>'
    }.GetNewClosure()
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender $sender
    $versions = @(Get-VcdApiVersions -Client $client)
    Assert-Equal 2 $versions.Count
    Assert-Equal '39.0' $versions[1]
    Assert-Equal 'GET' $calls[0].Method
    Assert-Equal 'https://vcd.example.test/api/versions' $calls[0].Uri
    Assert-Equal 'application/*+xml' $calls[0].Headers.Accept
}

Invoke-TestCase -Name 'Mocked API returns firewall rules using NSX-T v2 endpoint' -Body {
    $calls = [System.Collections.Generic.List[object]]::new()
    $sender = {
        param($request)
        $calls.Add($request)
        [pscustomobject]@{ userDefinedRules = @([pscustomobject]@{ id = 'rule-1'; name = 'Web' }) }
    }.GetNewClosure()
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender $sender
    $result = Get-VcdEdgeFirewallRules -Client $client -GatewayId 'urn:vcloud:gateway:aaa'
    Assert-Equal 'Web' $result.userDefinedRules[0].name
    Assert-Equal 'GET' $calls[0].Method
    Assert-True ($calls[0].Uri -like 'https://vcd.example.test/cloudapi/2.0.0/edgeGateways/*/firewall/rules')
    Assert-Equal 'application/json;version=39.0' $calls[0].Headers.Accept
}

Invoke-TestCase -Name 'Mocked API paginates firewall groups and preserves filtered gateway ID' -Body {
    $calls = [System.Collections.Generic.List[object]]::new()
    $sender = {
        param($request)
        $calls.Add($request)
        if ($request.Uri -match 'page=1(?:&|$)') {
            return [pscustomobject]@{ values = @([pscustomobject]@{ id = 'group-1'; typeValue = 'IP_SET' }); pageCount = 2 }
        }
        [pscustomobject]@{ values = @([pscustomobject]@{ id = 'group-2'; typeValue = 'IP_SET' }); pageCount = 2 }
    }.GetNewClosure()
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender $sender
    $groups = @(Get-VcdFirewallGroups -Client $client -GatewayId 'urn:vcloud:gateway:aaa')
    Assert-Equal 2 $groups.Count
    Assert-Equal 'group-2' $groups[1].id
    Assert-Equal 2 $calls.Count
    Assert-True ([uri]::UnescapeDataString($calls[0].Uri) -match 'edgeGatewayId==urn:vcloud:gateway:aaa')
    Assert-True ($calls[1].Uri -match 'page=2')
    Assert-True ($calls[0].Uri -match 'pageSize=100')
}

Invoke-TestCase -Name 'Mocked API filters manual IP reservations by network URN' -Body {
    $calls = [System.Collections.Generic.List[object]]::new()
    $sender = {
        param($request)
        $calls.Add($request)
        [pscustomobject]@{ values = @([pscustomobject]@{ id = 'reservation-1'; ipAddresses = '10.1.2.3' }); pageCount = 1 }
    }.GetNewClosure()
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender $sender
    $reservations = @(Get-VcdManualIpReservations -Client $client -NetworkId 'urn:vcloud:network:xyz')
    Assert-Equal 1 $reservations.Count
    Assert-Equal '10.1.2.3' $reservations[0].ipAddresses
    Assert-True ($calls[0].Uri -match '/cloudapi/1.0.0/manualIpReservations')
    Assert-True ([uri]::UnescapeDataString($calls[0].Uri) -match 'networkRef.id==urn:vcloud:network:xyz')
}

Invoke-TestCase -Name 'Transport errors, malformed versions and invalid pagination surface explicitly' -Body {
    $fail = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender { param($request) throw 'HTTP 503 synthetic' }
    Assert-Throws { Get-VcdEdgeFirewallRules -Client $fail -GatewayId 'gateway' } 'HTTP errors should propagate'
    $badXml = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender { param($request) 'invalid<xml' }
    Assert-Throws { Get-VcdApiVersions -Client $badXml } 'XML failures should surface'
    $badPage = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender { param($request) [pscustomobject]@{ pageCount=1 } }
    Assert-Throws { Get-VcdFirewallGroups -Client $badPage -GatewayId 'g' }
    $empty = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender { param($request) [pscustomobject]@{ pageCount=0; values=@() } }
    Assert-Equal 0 (@(Get-VcdFirewallGroups -Client $empty -GatewayId 'g').Count)
    $badCount = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender { param($request) [pscustomobject]@{ pageCount=0; values=@('invalid') } }
    Assert-Throws { Get-VcdFirewallGroups -Client $badCount -GatewayId 'g' }
}

Invoke-TestCase -Name 'API boundary rejects invalid paths, blanks and out-of-range page sizes' -Body {
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender { param($request) throw 'Unexpected request sent' }
    foreach ($path in @('//attacker.example/test','/../admin','/a/../../b','relative','/a\\b','/a#fragment')) {
        Assert-Throws { Invoke-VcdRead -Client $client -Path $path } "Unexpected valid path $path"
    }
    Assert-Throws { Get-VcdEdgeFirewallRules -Client $client -GatewayId ' ' }
    Assert-Throws { Get-VcdManualIpReservations -Client $client -NetworkId '' }
    Assert-Throws { Invoke-VcdPagedRead -Client $client -ResourcePath '/x' -Filter '(a==b)' -PageSize 129 }
}

Invoke-TestCase -Name 'API module performs no real HTTP operations or mutation' -Body {
    $path = Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdApi.psm1'
    $source = [IO.File]::ReadAllText($path)
    foreach ($verb in @('Invoke-RestMethod','Invoke-WebRequest','HttpClient','WebRequest')) {
        Assert-True (-not $source.Contains($verb)) "API boundary unexpectedly contains $verb"
    }
    # Operations are read-only until the deployment phase.
    Assert-True ($source.Contains("Method = 'GET'"))
    Assert-True (-not $source.Contains("Method = 'POST'"))
    Assert-True (-not $source.Contains("Method = 'DELETE'"))
}

. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcd.ps1')
Invoke-TestCase -Name 'Fixture-backed fake VCD handles every Phase 1 API request without HTTP' -Body {
    $fake = New-FakeVcdEnvironment -FixturesDirectory (Join-Path $ProjectRoot 'tests\Fixtures')
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender $fake.RequestSender
    Assert-Equal 2 (@(Get-VcdApiVersions -Client $client).Count)
    $rules = Get-VcdEdgeFirewallRules -Client $client -GatewayId 'urn:vcloud:gateway:one'
    Assert-Equal 'Allow Web' $rules.userDefinedRules[0].name
    $groups = @(Get-VcdFirewallGroups -Client $client -GatewayId 'urn:vcloud:gateway:one')
    Assert-Equal 2 $groups.Count
    Assert-Equal 'IP_SET' $groups[0].typeValue
    $reservations = @(Get-VcdManualIpReservations -Client $client -NetworkId 'urn:vcloud:network:one')
    Assert-Equal 1 $reservations.Count
    Assert-Equal 5 $fake.Calls.Count
    Assert-True ((@($fake.Calls | Where-Object { $_.Method -ne 'GET' })).Count -eq 0)
    Assert-Throws { & $fake.RequestSender ([pscustomobject]@{ Method='POST'; Uri='https://vcd.example.test/cloudapi/1.0.0/firewallGroups' }) }
    Assert-Throws { & $fake.RequestSender ([pscustomobject]@{ Method='GET'; Uri='https://vcd.example.test/unexpected' }) }
}

Invoke-TestCase -Name 'VCD reader rejects incomplete pagination with inconsistent resultTotal' -Body {
    $client = New-VcdApiClient -BaseUri 'https://vcd.example.test' -RequestSender {
        param($request)
        [pscustomobject]@{ page=1; pageCount=1; resultTotal=2; values=@([pscustomobject]@{id='one'}) }
    }
    Assert-Throws { Get-VcdFirewallGroups -Client $client -GatewayId 'gateway' } 'Incomplete paging must block snapshots'
}

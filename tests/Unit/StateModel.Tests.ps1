Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -Force

function ConvertTo-TestDocument {
    param([string]$ResourceKind, [string]$ItemsJson = '[]')
    return ('{{"schemaVersion":2,"resourceKind":"{0}","items":{1}}}' -f $ResourceKind,$ItemsJson | ConvertFrom-Json)
}

Invoke-TestCase -Name 'Empty state schema has all supported resource types' -Body {
    Assert-Equal 3 (@(Get-NetworkResourceKinds).Count)
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $doc = New-EmptyNetworkDocument -ResourceKind $kind
        Assert-Equal 2 $doc.schemaVersion
        Assert-Equal $kind $doc.resourceKind
        Assert-Equal 0 @($doc.items).Count
        Confirm-NetworkDocument -Document $doc
    }
}

Invoke-TestCase -Name 'Legacy schema migrates from resources to v2 items in memory' -Body {
    $raw = Get-Content (Join-Path $ProjectRoot 'tests\Fixtures\legacy-ip-sets-v1.json') -Raw | ConvertFrom-Json
    $doc = ConvertTo-NetworkStateDocument -InputObject $raw
    Assert-Equal 2 $doc.schemaVersion
    Assert-Equal 'ipSets' $doc.resourceKind
    Assert-Equal 1 @($doc.items).Count
    Assert-Equal 'web' $doc.items[0].key
}

Invoke-TestCase -Name 'Unknown and invalid schema is rejected without rewriting it' -Body {
    foreach ($raw in @('{"schemaVersion":3,"resourceKind":"ipSets","items":[]}',
                      '{"schemaVersion":0,"resourceKind":"ipSets","items":[]}',
                      '{"schemaVersion":"2","resourceKind":"ipSets","items":[]}',
                      '{"schemaVersion":2,"resourceKind":"invalid","items":[]}',
                      '{"resourceKind":"ipSets","items":[]}')) {
        Assert-Throws { ConvertTo-NetworkStateDocument -InputObject ($raw | ConvertFrom-Json) }
    }
}

Invoke-TestCase -Name 'IP Set address validation accepts IPv4 IPv6 and CIDR and rejects bad prefixes' -Body {
    foreach ($address in @('10.20.1.1','10.20.0.0/16','2001:db8::1','2001:db8::/64')) {
        Assert-True (Test-NetworkIpAddress -Address $address -AllowCidr) "Should accept '$address'"
    }
    foreach ($address in @('10.1.2.3/33','2001:db8::/129','this-is-not-an-ip','10.1.2.3/2/3','10.1.2.3/-1')) {
        Assert-True (-not (Test-NetworkIpAddress -Address $address -AllowCidr)) "Should reject '$address'"
    }
    Assert-True (-not (Test-NetworkIpAddress -Address '10.1.0.0/24')) 'IP reservations cannot contain CIDR'
}

Invoke-TestCase -Name 'Schema rejects unknown fields, duplicate IP Set keys and addresses' -Body {
    $items = '[{"key":"one","name":"One","addresses":["10.0.0.1"],"unexpected":true}]'
    Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'ipSets' $items) }
    $items = '[{"key":"one","name":"One","addresses":["10.0.0.1"]},{"key":"ONE","name":"Two","addresses":["10.0.0.2"]}]'
    Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'ipSets' $items) }
    $items = '[{"key":"one","name":"One","addresses":["10.0.0.1","10.0.0.1"]}]'
    Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'ipSets' $items) }
}

Invoke-TestCase -Name 'Firewall schema rejects invalid protocols, ports, orders and booleans' -Body {
    $baseline = '{"key":"allow-web","name":"Allow","order":10,"action":"ALLOW","enabled":true,"logging":true,"sourceIpSets":[],"destinationIpSets":[],"services":[{"protocol":"TCP","ports":["443"]}]}'
    foreach ($replacement in @(
        @('"order":10','"order":-1'),
        @('"logging":true','"logging":"yes"'),
        @('"action":"ALLOW"','"action":"INVALID"'),
        @('"protocol":"TCP"','"protocol":"GRE"'),
        @('"443"','"65536"'),
        @('"443"','"400-20"')
    )) {
        $item = $baseline.Replace($replacement[0],$replacement[1])
        Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'edgeFirewallRules' ("[$item]")) }
    }
    Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'edgeFirewallRules' ("[$baseline,$baseline]")) }
}

Invoke-TestCase -Name 'Reservation schema rejects invalid IP address and missing network' -Body {
    Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'manualIpReservations' '[{"key":"bad","networkId":"n","address":"1.2.3.0/24"}]') }
    Assert-Throws { Confirm-NetworkDocument (ConvertTo-TestDocument 'manualIpReservations' '[{"key":"bad","networkId":"","address":"10.0.0.1"}]') }
}

Invoke-TestCase -Name 'Canonical item ignores object property ordering and set ordering' -Body {
    $one = '{"key":"a","name":"A","addresses":["10.1.1.2","10.1.1.1"]}' | ConvertFrom-Json
    $two = '{"addresses":["10.1.1.1","10.1.1.2"],"name":"A","key":"a"}' | ConvertFrom-Json
    Assert-Equal (Get-NetworkCanonicalItem $one) (Get-NetworkCanonicalItem $two)
}

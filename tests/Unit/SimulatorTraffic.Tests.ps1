Import-Module (Join-Path $ProjectRoot 'src\Domain\Traffic\Traffic.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -ErrorAction Stop

Invoke-TestCase -Name 'Synthetic traffic matches exact IPv4 and IPv6 CIDRs correctly' -Body {
    Assert-True (Test-SimulatorIpMatch '192.0.2.7' '192.0.2.0/24')
    Assert-True (-not (Test-SimulatorIpMatch '192.0.3.7' '192.0.2.0/24'))
    Assert-True (Test-SimulatorIpMatch '2001:db8::1' '2001:db8::/32')
    Assert-True (-not (Test-SimulatorIpMatch '2001:db9::1' '2001:db8::/32'))
    Assert-True (-not (Test-SimulatorIpMatch 'garbage' '0.0.0.0/0'))
}

Invoke-TestCase -Name 'Traffic uses first enabled matching rule and service/port restrictions' -Body {
    $docs=[ordered]@{}
    foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $docs[$kind]=New-EmptyNetworkDocument $kind }
    $docs.ipSets.items=@([pscustomobject]@{key='client';name='Client';addresses=@('192.0.2.0/24')})
    $docs.edgeFirewallRules.items=@(
        [pscustomobject]@{key='deny-ssh';name='Deny SSH';order=0;action='DROP';enabled=$true;logging=$true;sourceIpSets=@('client');destinationIpSets=@();services=@([pscustomobject]@{protocol='TCP';ports=@('22')})},
        [pscustomobject]@{key='allow-web';name='Web';order=1;action='ALLOW';enabled=$true;logging=$true;sourceIpSets=@('client');destinationIpSets=@();services=@([pscustomobject]@{protocol='TCP';ports=@('443','8000-8010')})}
    )
    $blocked=Test-SimulatorFlow -Documents $docs -SourceIp '192.0.2.5' -DestinationIp '198.51.100.10' -Protocol TCP -DestinationPort 22
    Assert-Equal 'Denied' $blocked.verdict
    Assert-Equal 'deny-ssh' $blocked.matchedRuleKey
    $allowed=Test-SimulatorFlow -Documents $docs -SourceIp '192.0.2.5' -DestinationIp '198.51.100.10' -Protocol TCP -DestinationPort 8005
    Assert-Equal 'Allowed' $allowed.verdict
    Assert-Equal 'allow-web' $allowed.matchedRuleKey
    $default=Test-SimulatorFlow -Documents $docs -SourceIp '198.51.100.4' -DestinationIp '198.51.100.10' -Protocol TCP -DestinationPort 443
    Assert-Equal 'Default deny' $default.matchedRuleName
    $docs.edgeFirewallRules.items[1].enabled=$false
    Assert-Equal 'Denied' (Test-SimulatorFlow -Documents $docs -SourceIp '192.0.2.5' -DestinationIp '198.51.100.10' -Protocol TCP -DestinationPort 443).verdict
}

Invoke-TestCase -Name 'Traffic rejects malformed addresses and missing TCP port' -Body {
    $docs=[ordered]@{}
    foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $docs[$kind]=New-EmptyNetworkDocument $kind }
    Assert-Throws { Test-SimulatorFlow -Documents $docs -SourceIp 'bad' -DestinationIp '192.0.2.5' -Protocol TCP -DestinationPort 443 }
    Assert-Throws { Test-SimulatorFlow -Documents $docs -SourceIp '192.0.2.4' -DestinationIp '192.0.2.5' -Protocol TCP }
}

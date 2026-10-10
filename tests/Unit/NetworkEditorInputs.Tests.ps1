Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkEditorInputs.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -ErrorAction Stop

Invoke-TestCase -Name 'IP Set form converts addresses and CIDRs without requiring JSON' -Body {
    $item=ConvertTo-NetworkEditorItem -ResourceKind ipSets -Fields @{
        Name='Production Web Servers';Key='';Description='Web tier';Addresses="192.0.2.10`r`n192.0.2.0/24, 2001:db8::10"
    }
    Assert-Equal 'production-web-servers' $item.key
    Assert-Equal 3 @($item.addresses).Count
    Assert-Equal '192.0.2.0/24' $item.addresses[1]
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind ipSets -Fields @{Name='Bad';Key='';Description='';Addresses='192.0.2.999'} }
}

Invoke-TestCase -Name 'Firewall form converts multiple services and selected named IP Sets' -Body {
    $item=ConvertTo-NetworkEditorItem -ResourceKind edgeFirewallRules -Fields @{
        Name='HTTPS Web';Key='https-web';Description='Ticket 123';Order=2;Action='ALLOW';Enabled=$true;Logging=$true
        Sources=@('web-servers');Destinations=@('app-servers')
        Services=@(@{Protocol='TCP';Ports='443, 8443-8450'},@{Protocol='UDP';Ports='53'})
    }
    Assert-Equal 2 @($item.services).Count
    Assert-Equal '8443-8450' $item.services[0].ports[1]
    Assert-Equal 'web-servers' $item.sourceIpSets[0]
    Assert-True ($item.enabled -and $item.logging)
}

Invoke-TestCase -Name 'Firewall form can express any sources destinations and services' -Body {
    $item=ConvertTo-NetworkEditorItem -ResourceKind edgeFirewallRules -Fields @{
        Name='Deny everything';Key='';Description='';Order=0;Action='DROP';Enabled=$true;Logging=$true
        Sources=@();Destinations=@();Services=@()
    }
    Assert-Equal 0 @($item.services).Count
    Assert-Equal 0 @($item.sourceIpSets).Count
    Assert-Equal 'deny-everything' $item.key
}

Invoke-TestCase -Name 'Network engineers cannot input invalid protocols ports or duplicate IPs' -Body {
    $base=@{Name='Invalid';Key='invalid';Description='';Order=0;Action='ALLOW';Enabled=$true;Logging=$false;Sources=@();Destinations=@()}
    $base.Services=@(@{Protocol='TCP';Ports='0'})
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind edgeFirewallRules -Fields $base }
    $base.Services=@(@{Protocol='ICMP';Ports='443'})
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind edgeFirewallRules -Fields $base }
    $base.Services=@(@{Protocol='BOGUS';Ports=''})
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind edgeFirewallRules -Fields $base }
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind ipSets -Fields @{Name='Duplicate';Key='';Description='';Addresses='10.0.0.1, 10.0.0.1'} }
}

Invoke-TestCase -Name 'IP reservation form requires valid single address and network' -Body {
    $reservation=ConvertTo-NetworkEditorItem -ResourceKind manualIpReservations -Fields @{
        Key='';NetworkId='urn:vcloud:network:00000000-0000-0000-0000-000000000001';Address='192.0.2.70';Description='Reserved host'
    }
    Assert-Equal 'reservation-192.0.2.70' $reservation.key
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind manualIpReservations -Fields @{Key='';NetworkId='';Address='192.0.2.70';Description=''} }
    Assert-Throws { ConvertTo-NetworkEditorItem -ResourceKind manualIpReservations -Fields @{Key='';NetworkId='net';Address='192.0.2.0/24';Description=''} }
}

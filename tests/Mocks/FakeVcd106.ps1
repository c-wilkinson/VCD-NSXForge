# Offline API 39.0 fixture responder; never opens a socket or accepts writes.
# Synthetic examples model a VCD 10.6 NSX-T environment; no captured credentials.
function Read-Vcd106Fixture {
    param([Parameter(Mandatory)][string]$Name)
    $file = Join-Path $ProjectRoot ('tests\Fixtures\Vcd106\' + $Name)
    if ($Name -eq 'versions.xml') { return [IO.File]::ReadAllText($file) }
    return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file)) -ErrorAction Stop)
}

function New-FakeVcd106 {
    param(
        [string]$Origin = 'https://vcd.example.test:8443',
        [string]$GatewayId = 'urn:vcloud:gateway:55555555-5555-4555-8555-555555555555',
        [string]$NetworkId = 'urn:vcloud:network:44444444-4444-4444-8444-444444444444'
    )
    $calls = [System.Collections.Generic.List[object]]::new()
    $versions = Read-Vcd106Fixture 'versions.xml'
    $session = Read-Vcd106Fixture 'session-current.json'
    $firewall = Read-Vcd106Fixture 'edge-firewall-rules.json'
    $group1 = Read-Vcd106Fixture 'firewall-groups-page1.json'
    $group2 = Read-Vcd106Fixture 'firewall-groups-page2.json'
    $detail = Read-Vcd106Fixture 'firewall-group-ipset.json'
    $reservations = Read-Vcd106Fixture 'manual-ip-reservations.json'
    $sender = {
        param($request)
        if ($request.Method -cne 'GET') { throw 'FAKE_VCD_106_WRITE_BLOCKED' }
        $url = [uri]$request.Uri
        if ($url.GetLeftPart([System.UriPartial]::Authority) -cne $Origin -or $url.Scheme -cne 'https') {
            throw 'FAKE_VCD_106_EXTERNAL_ORIGIN_BLOCKED'
        }
        if ($null -eq $request.Headers -or -not $request.Headers.ContainsKey('Accept')) {
            throw 'FAKE_VCD_106_MISSING_ACCEPT'
        }
        $calls.Add($request)
        switch -Regex ($url.AbsolutePath) {
            '^/api/versions$' {
                if ($request.Headers.Accept -cne 'application/*+xml') { throw 'FAKE_VCD_106_WRONG_ACCEPT' }
                return $versions
            }
            '^/cloudapi/1.0.0/sessions/current$' { return $session }
            '^/cloudapi/1.0.0/edgeGateways/([^/]+)$' {
                if ([uri]::UnescapeDataString($Matches[1]) -cne $GatewayId) { throw 'FAKE_VCD_106_WRONG_GATEWAY' }
                return [pscustomobject]@{ id=$GatewayId; orgRef=[pscustomobject]@{id='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'} }
            }
            '^/cloudapi/1.0.0/orgVdcNetworks/([^/]+)$' {
                if ([uri]::UnescapeDataString($Matches[1]) -cne $NetworkId) { throw 'FAKE_VCD_106_WRONG_NETWORK' }
                return [pscustomobject]@{ id=$NetworkId; orgRef=[pscustomobject]@{id='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'} }
            }
            '^/cloudapi/2.0.0/edgeGateways/([^/]+)/firewall/rules$' {
                if ([uri]::UnescapeDataString($Matches[1]) -cne $GatewayId) { throw 'FAKE_VCD_106_WRONG_GATEWAY' }
                return $firewall
            }
            '^/cloudapi/1.0.0/firewallGroups/summaries$' {
                $q = [uri]::UnescapeDataString($url.Query)
                if ($q -cnotmatch [regex]::Escape('(edgeGatewayId==' + $GatewayId + ')')) { throw 'FAKE_VCD_106_UNSCOPED_GROUPS' }
                if ($q -notmatch '(?:\?|&)page=([0-9]+)' -or $q -notmatch '(?:\?|&)pageSize=([0-9]+)') { throw 'FAKE_VCD_106_NO_PAGING' }
                $page = [int]([regex]::Match($q, '(?:\?|&)page=([0-9]+)').Groups[1].Value)
                $size = [int]([regex]::Match($q, '(?:\?|&)pageSize=([0-9]+)').Groups[1].Value)
                if ($size -eq 1) {
                    if ($page -eq 1) { return $group1 }
                    if ($page -eq 2) { return $group2 }
                }
                elseif ($page -eq 1 -and $size -ge 2) {
                    return [pscustomobject]@{ page=1; pageSize=$size; pageCount=1; resultTotal=2; values=@($group1.values[0],$group2.values[0]) }
                }
                throw 'FAKE_VCD_106_PAGE_OUT_OF_RANGE'
            }
            '^/cloudapi/1.0.0/firewallGroups/([^/]+)$' {
                if ([uri]::UnescapeDataString($Matches[1]) -cne $detail.id) { throw 'FAKE_VCD_106_WRONG_GROUP' }
                return $detail
            }
            '^/cloudapi/1.0.0/manualIpReservations$' {
                $q = [uri]::UnescapeDataString($url.Query)
                if ($q -cnotmatch [regex]::Escape('(networkRef.id==' + $NetworkId + ')')) { throw 'FAKE_VCD_106_UNSCOPED_RESERVATIONS' }
                return $reservations
            }
            default { throw ('FAKE_VCD_106_UNKNOWN_ROUTE: ' + $url.AbsolutePath) }
        }
    }.GetNewClosure()
    return [pscustomobject]@{ RequestSender=$sender; Calls=$calls; GatewayId=$GatewayId; NetworkId=$NetworkId }
}

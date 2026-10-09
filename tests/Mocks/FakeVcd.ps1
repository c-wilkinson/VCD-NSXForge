# Strict fake of all API operations currently implemented by VcdApi.psm1.
# Unexpected requests fail closed, so new production API methods require new mocks.
function New-FakeVcdEnvironment {
    param([Parameter(Mandatory)][string]$FixturesDirectory)
    $calls = [System.Collections.Generic.List[object]]::new()
    $firewall = Get-Content -LiteralPath (Join-Path $FixturesDirectory 'edge-firewall-rules.json') -Raw | ConvertFrom-Json
    $groups1 = Get-Content -LiteralPath (Join-Path $FixturesDirectory 'firewall-groups-page1.json') -Raw | ConvertFrom-Json
    $groups2 = Get-Content -LiteralPath (Join-Path $FixturesDirectory 'firewall-groups-page2.json') -Raw | ConvertFrom-Json
    $reservations = Get-Content -LiteralPath (Join-Path $FixturesDirectory 'manual-ip-reservations.json') -Raw | ConvertFrom-Json
    $versions = '<SupportedVersions><VersionInfo><Version>38.1</Version></VersionInfo><VersionInfo><Version>39.0</Version></VersionInfo></SupportedVersions>'
    $sender = {
        param($request)
        $calls.Add($request)
        if ($request.Method -ne 'GET') { throw "FAKE_VCD_UNEXPECTED_METHOD: $($request.Method)" }
        $u = [uri]$request.Uri
        switch -Regex ($u.AbsolutePath) {
            '^/api/versions$' { return $versions }
            '^/cloudapi/2.0.0/edgeGateways/[^/]+/firewall/rules$' { return $firewall }
            '^/cloudapi/1.0.0/firewallGroups/summaries$' {
                $decoded = [uri]::UnescapeDataString($u.Query)
                if ($decoded -notmatch 'edgeGatewayId==') { throw 'FAKE_VCD_MISSING_GATEWAY_FILTER' }
                if ($decoded -match 'page=2') { return $groups2 }
                return $groups1
            }
            '^/cloudapi/1.0.0/manualIpReservations$' {
                $decoded = [uri]::UnescapeDataString($u.Query)
                if ($decoded -notmatch 'networkRef.id==') { throw 'FAKE_VCD_MISSING_NETWORK_FILTER' }
                return $reservations
            }
            default { throw "FAKE_VCD_UNEXPECTED_ROUTE: $($u.AbsolutePath)" }
        }
    }.GetNewClosure()
    [pscustomobject]@{ RequestSender = $sender; Calls = $calls }
}

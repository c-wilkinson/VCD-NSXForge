# Fake supports exactly the Phase 3 read-only route set, no real network.
function New-FakeVcdReadSender {
    param([Parameter(Mandatory)][string]$FixtureRoot, [switch]$UnsupportedFirewall, [switch]$HttpFailure)
    $calls = [System.Collections.Generic.List[object]]::new()
    $versions = [IO.File]::ReadAllText((Join-Path $FixtureRoot 'versions.xml'))
    $firewall = [IO.File]::ReadAllText((Join-Path $FixtureRoot 'firewall.json')) | ConvertFrom-Json
    $group = [IO.File]::ReadAllText((Join-Path $FixtureRoot 'group.json')) | ConvertFrom-Json
    $res = [IO.File]::ReadAllText((Join-Path $FixtureRoot 'reservations.json')) | ConvertFrom-Json
    if ($UnsupportedFirewall) { $firewall.userDefinedRules[0] | Add-Member -NotePropertyName applicationPortProfiles -NotePropertyValue @([pscustomobject]@{id='profile-1'}) }
    $simulateFailure = [bool]$HttpFailure
    $sender = {
        param($request)
        $calls.Add($request)
        if ($request.Method -cne 'GET') { throw 'Mutation is forbidden by mock.' }
        $url = [uri]$request.Uri
        if ($simulateFailure -and $url.AbsolutePath -like '*firewall/rules') { throw 'HTTP 503 simulated' }
        switch -Regex ($url.AbsolutePath) {
            '^/api/versions$' { return $versions }
            '^/cloudapi/1.0.0/sessions/current$' { return [pscustomobject]@{ id='urn:vcloud:session:demo' } }
            '^/cloudapi/2.0.0/edgeGateways/[^/]+/firewall/rules$' { return $firewall }
            '^/cloudapi/1.0.0/firewallGroups/summaries$' {
                return [pscustomobject]@{ pageCount=1; values=@([pscustomobject]@{ id=$group.id; name=$group.name; typeValue='IP_SET' }) }
            }
            '^/cloudapi/1.0.0/firewallGroups/[^/]+$' { return $group }
            '^/cloudapi/1.0.0/manualIpReservations$' { return $res }
            default { throw "Unexpected mocked route: $($url.AbsolutePath)" }
        }
    }.GetNewClosure()
    return [pscustomobject]@{ RequestSender=$sender; Calls=$calls }
}

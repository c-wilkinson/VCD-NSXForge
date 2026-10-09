Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorServer.psm1') -Force
$simulatorFixture = Join-Path $ProjectRoot 'simulator\topology.json'

Invoke-TestCase -Name 'Importing simulator server preserves caller-visible topology commands' -Body {
    # Production imports SimulatorServer directly; tests additionally import the policy.
    # The server must reuse, not forcibly reload, that shared dependency.
    foreach ($functionName in @('Import-SimulatorTopology', 'Test-SimulatorTopology', 'Get-SimulatorAccessDecision')) {
        $command = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
        Assert-Equal 'TopologyPolicy' $command.ModuleName
    }
    $data = Import-SimulatorTopology -Path $simulatorFixture
    Assert-Equal 6 @($data.gateways).Count
    $version = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/api/versions'
    Assert-Equal 200 $version.StatusCode
}

Invoke-TestCase -Name 'Simulator returns VCD 39.0 discovery and synthetic session response' -Body {
    $data = Import-SimulatorTopology -Path $simulatorFixture
    $version = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/api/versions'
    Assert-Equal 200 $version.StatusCode
    Assert-True ($version.Body -match '<Version>39.0</Version>')
    $guest = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/sessions/current'
    Assert-Equal 401 $guest.StatusCode
    $authenticated = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/sessions/current' -Authorization 'Bearer simulator-read-only'
    Assert-Equal 200 $authenticated.StatusCode
    Assert-True $authenticated.Body.synthetic
}

Invoke-TestCase -Name 'Simulator refuses all mutating VMware API methods' -Body {
    $data = Import-SimulatorTopology -Path $simulatorFixture
    foreach ($verb in @('PUT','PATCH','DELETE')) {
        $response = Invoke-SimulatorRoute -Dataset $data -Method $verb -Path '/cloudapi/1.0.0/firewallGroups/anything' -Authorization 'Bearer simulator-read-only'
        Assert-Equal 405 $response.StatusCode
    }
    $response = Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/cloudapi/2.0.0/edgeGateways/anything/firewall/rules' -Authorization 'Bearer simulator-read-only'
    Assert-Equal 405 $response.StatusCode
}

Invoke-TestCase -Name 'Simulator accepts only explicitly fake login credentials' -Body {
    $data = Import-SimulatorTopology -Path $simulatorFixture
    $wrong = Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/cloudapi/1.0.0/sessions' -Authorization 'Basic dXNlcjpwYXNzd29yZA=='
    Assert-Equal 401 $wrong.StatusCode
    $fake = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('simulator@local:simulator-only'))
    $valid = Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/cloudapi/1.0.0/sessions' -Authorization $fake
    Assert-Equal 200 $valid.StatusCode
}

Invoke-TestCase -Name 'Simulator returns firewall rules, IP sets and reservations for all six scopes' -Body {
    $data = Import-SimulatorTopology -Path $simulatorFixture
    foreach ($gateway in @($data.gateways)) {
        $firewall = Invoke-SimulatorRoute -Dataset $data -Method GET -Path ('/cloudapi/2.0.0/edgeGateways/' + [uri]::EscapeDataString($gateway.gatewayId) + '/firewall/rules') -Authorization 'Bearer simulator-read-only'
        Assert-Equal 200 $firewall.StatusCode
        Assert-Equal 1 @($firewall.Body.userDefinedRules).Count
        $sets = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/firewallGroups/summaries' -Query @{filter="(edgeGatewayId==$($gateway.gatewayId))";page='1';pageSize='100'} -Authorization 'Bearer simulator-read-only'
        Assert-Equal 200 $sets.StatusCode
        Assert-Equal 1 $sets.Body.resultTotal
        $group = Invoke-SimulatorRoute -Dataset $data -Method GET -Path ('/cloudapi/1.0.0/firewallGroups/' + [uri]::EscapeDataString($gateway.ipSets[0].id)) -Authorization 'Bearer simulator-read-only'
        Assert-Equal 200 $group.StatusCode
        Assert-Equal 2 @($group.Body.ipAddresses).Count
        $reservations = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/manualIpReservations' -Query @{filter="(networkRef.id==$($gateway.networkId))";page='1';pageSize='100'} -Authorization 'Bearer simulator-read-only'
        Assert-Equal 200 $reservations.StatusCode
        Assert-Equal 1 $reservations.Body.resultTotal
    }
}

Invoke-TestCase -Name 'Simulator pagination supports empty pages and rejects invalid filters' -Body {
    $data = Import-SimulatorTopology -Path $simulatorFixture
    $scope = $data.gateways[0]
    $second = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/firewallGroups/summaries' -Query @{filter="(edgeGatewayId==$($scope.gatewayId))";page='2';pageSize='1'} -Authorization 'Bearer simulator-read-only'
    Assert-Equal 0 @($second.Body.values).Count
    Assert-Equal 1 $second.Body.pageCount
    $invalid = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/firewallGroups/summaries' -Query @{filter='(bad==thing)'} -Authorization 'Bearer simulator-read-only'
    Assert-Equal 400 $invalid.StatusCode
    $unknown = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/cloudapi/1.0.0/noSuchEndpoint' -Authorization 'Bearer simulator-read-only'
    Assert-Equal 404 $unknown.StatusCode
}

Invoke-TestCase -Name 'Simulator debug endpoints explain authentication and management independently' -Body {
    $data = Import-SimulatorTopology -Path $simulatorFixture
    $topology = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/__simulator/v1/topology'
    Assert-Equal 200 $topology.StatusCode
    Assert-Equal 3 @($topology.Body.domains).Count
    $decision = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/__simulator/v1/access' -Query @{sourceDomain='DomainA';sourceTier='1';targetDomain='DomainB';targetTier='1'}
    Assert-Equal 200 $decision.StatusCode
    Assert-True $decision.Body.authenticationPossible
    Assert-True (-not $decision.Body.canManage)
    $invalid = Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/__simulator/v1/access' -Query @{sourceDomain='DomainZ';sourceTier='0';targetDomain='DomainB';targetTier='1'}
    Assert-Equal 400 $invalid.StatusCode
}

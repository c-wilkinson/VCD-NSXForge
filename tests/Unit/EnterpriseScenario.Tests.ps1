# Enterprise lab is a separate synthetic scenario and must not change base fixtures.
Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Traffic\Traffic.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorServer.psm1') -ErrorAction Stop
$enterpriseScenarioRoot = Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab'

Invoke-TestCase -Name 'Enterprise lab contains six valid scopes and at least seventy synthetic servers and firewall rules' -Body {
    $data = Import-SimulatorTopology -Path (Join-Path $enterpriseScenarioRoot 'topology.json')
    Assert-Equal 6 @($data.gateways).Count
    Assert-True (@($data.gateways | ForEach-Object { $_.firewall.userDefinedRules }).Count -ge 70)
    Assert-True (@($data.gateways | ForEach-Object { $_.ipSets }).Count -ge 70)
    $assets = Get-Content -LiteralPath (Join-Path $enterpriseScenarioRoot 'inventory.json') -Raw | ConvertFrom-Json
    Assert-True $assets.synthetic
    Assert-True (@($assets.hosts).Count -ge 70)
    $null = Initialize-SimulatorWorkspace -Dataset $data
    foreach ($gateway in @($data.gateways)) {
        $snapshot = Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
        Assert-True (@($snapshot.documents.edgeFirewallRules.items).Count -gt 0)
        Assert-Equal @($gateway.firewall.userDefinedRules).Count @($snapshot.documents.edgeFirewallRules.items).Count
    }
}

Invoke-TestCase -Name 'Enterprise lab exposes SQL FCI RDS MCM SCM and Azure DevOps in DomainB Tier 1' -Body {
    $data = Import-SimulatorTopology -Path (Join-Path $enterpriseScenarioRoot 'topology.json')
    $assets = Get-Content -LiteralPath (Join-Path $enterpriseScenarioRoot 'inventory.json') -Raw | ConvertFrom-Json
    foreach ($name in @('B-SQL01','B-SQL02','B-SQLFCI','B-FILE01','B-RDSGW01','B-RDSH01','B-MCM01','B-SCM01','B-ADO01','B-AGENT01','C-SQLDR01')) {
        Assert-Equal 1 @($assets.hosts | Where-Object { $_.hostname -ceq $name }).Count
    }
    $gw = @($data.gateways | Where-Object { $_.domain -eq 'DomainB' -and $_.tier -eq 1 })[0]
    Assert-True (@($gw.firewall.userDefinedRules).Count -ge 20)
    Assert-True (@($gw.ipSets).Count -ge 20)
}

Invoke-TestCase -Name 'Enterprise lab curated flows resolve to expected first matching rules and decisions' -Body {
    $data = Initialize-SimulatorWorkspace -Dataset (Import-SimulatorTopology -Path (Join-Path $enterpriseScenarioRoot 'topology.json'))
    $flows = Get-Content -LiteralPath (Join-Path $enterpriseScenarioRoot 'flow-cases.json') -Raw | ConvertFrom-Json
    Assert-True (@($flows.cases).Count -ge 30)
    foreach ($case in @($flows.cases)) {
        $snapshot = Get-SimulatorWorkspaceState -Dataset $data -GatewayId ([string]$case.gatewayId)
        $decision = Test-SimulatorFlow -Documents $snapshot.documents -SourceIp ([string]$case.sourceIp) -DestinationIp ([string]$case.destinationIp) -Protocol ([string]$case.protocol) -DestinationPort ([int]$case.destinationPort)
        Assert-Equal ([string]$case.expectedVerdict) ([string]$decision.verdict) "Verdict: $($case.name)"
        Assert-Equal ([string]$case.expectedMatchedRule) ([string]$decision.matchedRuleName) "Rule: $($case.name)"
    }
}

Invoke-TestCase -Name 'Enterprise lab trusts and administration remain asymmetric' -Body {
    $data = Import-SimulatorTopology -Path (Join-Path $enterpriseScenarioRoot 'topology.json')
    $allowed = Get-SimulatorAccessDecision -Dataset $data -SourceDomain 'DomainA' -SourceTier 0 -TargetDomain 'DomainB' -TargetTier 1
    Assert-True $allowed.canManage
    $denied = Get-SimulatorAccessDecision -Dataset $data -SourceDomain 'DomainB' -SourceTier 1 -TargetDomain 'DomainA' -TargetTier 0
    Assert-True (-not $denied.canManage)
}

Invoke-TestCase -Name 'Enterprise lab launcher keeps separate topology and runtime state files' -Body {
    $launcher = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tools\Start-EnterpriseLab.ps1') -Raw
    Assert-True ($launcher.Contains('enterprise-lab\topology.json'))
    Assert-True ($launcher.Contains('runtime-state.json.enterprise-lab'))
    Assert-True (-not $launcher.Contains("[IO.File]::Delete((Join-Path `$root 'simulator\runtime-state.json'))"))
}

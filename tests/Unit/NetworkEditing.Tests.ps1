Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
$topologyFixture=Join-Path $ProjectRoot 'simulator\topology.json'

Invoke-TestCase -Name 'Editor creates updates and deletes an IP Set without mutating baseline' -Body {
    $data=Import-SimulatorTopology -Path $topologyFixture
    $gateway=$data.gateways[0]
    $baseline=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $docs=Copy-NetworkDocuments $baseline.documents
    $set=[pscustomobject]@{key='frontend';name='Frontend';description='';addresses=@('192.0.2.10','192.0.2.11')}
    $added=Set-NetworkDraftItem -Documents $docs -ResourceKind ipSets -Item $set -Create
    Assert-Equal 2 @($added.ipSets.items).Count
    Assert-Equal 1 @($docs.ipSets.items).Count
    Assert-Throws { Set-NetworkDraftItem -Documents $added -ResourceKind ipSets -Item $set -Create }
    $set.name='Frontend Updated'
    $changed=Set-NetworkDraftItem -Documents $added -ResourceKind ipSets -Item $set
    Assert-Equal 'Frontend Updated' ([string](@($changed.ipSets.items | Where-Object {$_.key -eq 'frontend'})[0].name))
    $removed=Remove-NetworkDraftItem -Documents $changed -ResourceKind ipSets -Key 'frontend'
    Assert-Equal 1 @($removed.ipSets.items).Count
}

Invoke-TestCase -Name 'Editor enforces referential integrity and rejects malformed firewall rules' -Body {
    $data=Import-SimulatorTopology -Path $topologyFixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    $key=$docs.ipSets.items[0].key
    Assert-Throws { Remove-NetworkDraftItem -Documents $docs -ResourceKind ipSets -Key $key }
    $newRule=[pscustomobject]@{key='invalid-rule';name='Bad';description='';order=1;action='ALLOW';enabled=$true;logging=$false;sourceIpSets=@('not-there');destinationIpSets=@();services=@()}
    Assert-Throws { Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $newRule -Create }
    $newRule.sourceIpSets=@();$newRule.services=@([pscustomobject]@{protocol='TCP';ports=@('99999')})
    Assert-Throws { Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $newRule -Create }
}

Invoke-TestCase -Name 'Editor reorder produces a Move plan and preserves rule positions' -Body {
    $data=Import-SimulatorTopology -Path $topologyFixture
    $current=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId
    $item=[pscustomobject]@{key='another-rule';name='Second';description='';order=1;action='DROP';enabled=$true;logging=$true;sourceIpSets=@();destinationIpSets=@();services=@()}
    $docs=Set-NetworkDraftItem -Documents $current.documents -ResourceKind edgeFirewallRules -Item $item -Create
    $moved=Move-NetworkDraftRule -Documents $docs -Key 'another-rule' -Direction Up
    Assert-Equal 0 ([int](@($moved.edgeFirewallRules.items | Where-Object {$_.key -eq 'another-rule'})[0].order))
    Assert-Equal 1 ([int](@($moved.edgeFirewallRules.items | Where-Object {$_.key -ne 'another-rule'})[0].order))
    $plan=New-SimulatorDocumentPlan -DesiredDocuments $moved -CurrentDocuments $docs -Scope $current.gatewayId
    Assert-Equal 2 $plan.summary.Move
    Assert-True (-not $plan.blocked)
}

Invoke-TestCase -Name 'Editor updates firewall enabled state, action and reservation address' -Body {
    $data=Import-SimulatorTopology -Path $topologyFixture
    $gateway=$data.gateways[2]
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).documents
    $rule=$docs.edgeFirewallRules.items[0]
    $updatedRule=(ConvertTo-Json $rule -Depth 15 | ConvertFrom-Json)
    $updatedRule.enabled=$false
    $updatedRule.action='DROP'
    $changed=Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $updatedRule
    Assert-True (-not $changed.edgeFirewallRules.items[0].enabled)
    Assert-Equal 'DROP' $changed.edgeFirewallRules.items[0].action
    Assert-True $docs.edgeFirewallRules.items[0].enabled
    $reservation=($changed.manualIpReservations.items[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $reservation.address='192.0.2.71'
    $changed=Set-NetworkDraftItem -Documents $changed -ResourceKind manualIpReservations -Item $reservation
    Assert-Equal '192.0.2.71' $changed.manualIpReservations.items[0].address
    Assert-Throws { Set-NetworkDraftItem -Documents $changed -ResourceKind manualIpReservations -Item $reservation -Create }
}

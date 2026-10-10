Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorServer.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\Simulator\SimulatorClient.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
$syntheticFixture=Join-Path $ProjectRoot 'simulator\topology.json'

Invoke-TestCase -Name 'Simulator mutation tests resolve draft-copy API and preserve baseline isolation' -Body {
    $command = Get-Command -Name 'Copy-NetworkDocuments' -CommandType Function -ErrorAction Stop
    Assert-Equal 'NetworkEditing' $command.ModuleName
    $data = Import-SimulatorTopology -Path $syntheticFixture
    $gateway = $data.gateways[0]
    $baseline = Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $copy = Copy-NetworkDocuments -Documents $baseline.documents
    Assert-Equal ([string]$baseline.documents.ipSets.items[0].name) ([string]$copy.ipSets.items[0].name)
    $copy.ipSets.items[0].name = 'Changed only in the copy'
    Assert-True ($baseline.documents.ipSets.items[0].name -cne $copy.ipSets.items[0].name) 'Copy-NetworkDocuments must be independent of the input.'
}

Invoke-TestCase -Name 'Simulator can add, update, reorder and delete synthetic network resources atomically' -Body {
    $data=Import-SimulatorTopology -Path $syntheticFixture
    $gateway=@($data.gateways | Where-Object { $_.domain -eq 'DomainB' -and $_.tier -eq 1 })[0]
    $current=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $docs=Copy-NetworkDocuments $current.documents
    $docs.ipSets.items+= [pscustomobject]@{key='new-team';name='New team';description='';addresses=@('192.0.2.0/24')}
    $docs.edgeFirewallRules.items+= [pscustomobject]@{key='allow-new-team';name='Allow New Team';description='';order=1;action='ALLOW';enabled=$true;logging=$true;sourceIpSets=@('new-team');destinationIpSets=@();services=@([pscustomobject]@{protocol='TCP';ports=@('443')})}
    $docs.manualIpReservations.items+= [pscustomobject]@{key='reserved-team';networkId=$gateway.networkId;address='192.0.2.35';description='Synthetic'}
    $approved=Get-SimulatorDraftPlan -Baseline $current -DesiredDocuments $docs
    Assert-Equal 3 $approved.plan.summary.Create
    $request=([pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=0;planDigest=$approved.planDigest;documents=$docs;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    $response=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request
    Assert-Equal 200 $response.StatusCode
    Assert-Equal 1 $response.Body.revision
    $after=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    Assert-Equal 2 @($after.documents.ipSets.items).Count
    Assert-Equal 2 @($after.documents.edgeFirewallRules.items).Count
    Assert-Equal 2 @($after.documents.manualIpReservations.items).Count
    $vcdRead=Invoke-SimulatorRoute -Dataset $data -Method GET -Path ('/cloudapi/2.0.0/edgeGateways/'+[uri]::EscapeDataString($gateway.gatewayId)+'/firewall/rules') -Authorization 'Bearer simulator-read-only'
    Assert-Equal 2 @($vcdRead.Body.userDefinedRules).Count
    $update=Copy-NetworkDocuments $after.documents
    $update.edgeFirewallRules.items=@($update.edgeFirewallRules.items | Where-Object {$_.key -ne 'allow-new-team'})
    $update.ipSets.items=@($update.ipSets.items | Where-Object {$_.key -ne 'new-team'})
    $update.manualIpReservations.items=@($update.manualIpReservations.items | Where-Object {$_.key -ne 'reserved-team'})
    $update.edgeFirewallRules.items[0].name='Renamed existing rule'
    $approved2=Get-SimulatorDraftPlan -Baseline $after -DesiredDocuments $update
    Assert-Equal 1 $approved2.plan.summary.Update
    # 3 deletions: rule, IP set and reservation
    Assert-Equal 3 $approved2.plan.summary.Delete
    $request2=([pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=1;planDigest=$approved2.planDigest;documents=$update;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    $done=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request2
    Assert-Equal 200 $done.StatusCode
    Assert-Equal 1 @((Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).documents.ipSets.items).Count
}

Invoke-TestCase -Name 'Simulator apply rejects stale revisions, forged digest, actor restrictions and live-shaped mutations' -Body {
    $data=Import-SimulatorTopology -Path $syntheticFixture
    $gateway=@($data.gateways | Where-Object { $_.domain -eq 'DomainB' -and $_.tier -eq 1 })[0]
    $current=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $approved=Get-SimulatorDraftPlan -Baseline $current -DesiredDocuments $current.documents
    $request=([pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=9;planDigest=$approved.planDigest;documents=$current.documents;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    Assert-Equal 409 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request).StatusCode
    $request.expectedRevision=0;$request.planDigest='bad'
    Assert-Equal 409 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request).StatusCode
    $request.planDigest=$approved.planDigest;$request.actorDomain='DomainC';$request.actorTier=1
    Assert-Equal 403 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request).StatusCode
    Assert-Equal 403 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-read-only' -RequestBody $request).StatusCode
    Assert-Equal 405 (Invoke-SimulatorRoute -Dataset $data -Method PUT -Path '/cloudapi/1.0.0/firewallGroups/abc' -Authorization 'Bearer simulator-edit-only' -RequestBody $request).StatusCode
    Assert-Equal 0 (Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).revision
}

Invoke-TestCase -Name 'Synthetic traffic history records matched rules and verdicts independently per gateway' -Body {
    $data=Import-SimulatorTopology -Path $syntheticFixture
    $gateway=$data.gateways[0]
    $request=[pscustomobject]@{gatewayId=$gateway.gatewayId;sourceIp='10.50.10.10';destinationIp='10.50.10.99';protocol='TCP';destinationPort=443}
    $created=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/traffic' -Authorization 'Bearer simulator-edit-only' -RequestBody $request
    Assert-Equal 200 $created.StatusCode
    Assert-Equal 'Allowed' $created.Body.verdict
    Assert-True ($created.Body.matchedRuleKey -like 'vcd-*')
    $history=Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/__simulator/v1/traffic' -Query @{gatewayId=$gateway.gatewayId} -Authorization 'Bearer simulator-read-only'
    Assert-Equal 1 @($history.Body.events).Count
    $another=Invoke-SimulatorRoute -Dataset $data -Method GET -Path '/__simulator/v1/traffic' -Query @{gatewayId=$data.gateways[1].gatewayId} -Authorization 'Bearer simulator-read-only'
    Assert-Equal 0 @($another.Body.events).Count
}

Invoke-TestCase -Name 'Simulator persistence survives restart and cannot accept corrupt state' -Body {
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('vcd-phase4-'+[guid]::NewGuid().ToString('n'))
    $persist=Join-Path $scratch 'simulator.json'
    try {
        $data=Initialize-SimulatorWorkspace -Dataset (Import-SimulatorTopology -Path $syntheticFixture) -PersistencePath $persist
        $current=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId
        $approved=Get-SimulatorDraftPlan -Baseline $current -DesiredDocuments $current.documents
        $request=([pscustomobject]@{gatewayId=$current.gatewayId;expectedRevision=0;planDigest=$approved.planDigest;documents=$current.documents;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
        Assert-Equal 200 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request).StatusCode
        Assert-True ([IO.File]::Exists($persist))
        $reloaded=Initialize-SimulatorWorkspace -Dataset (Import-SimulatorTopology -Path $syntheticFixture) -PersistencePath $persist
        Assert-Equal 1 (Get-SimulatorWorkspaceState -Dataset $reloaded -GatewayId $current.gatewayId).revision
        [IO.File]::WriteAllText($persist,'{"schemaVersion":99}')
        Assert-Throws { Initialize-SimulatorWorkspace -Dataset (Import-SimulatorTopology -Path $syntheticFixture) -PersistencePath $persist }
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) } }
}

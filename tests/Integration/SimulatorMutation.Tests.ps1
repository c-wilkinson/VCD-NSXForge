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
    $request=([pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=0;approvalVersion=$approved.approvalVersion;baselineDigest=$approved.baselineDigest;desiredDigest=$approved.desiredDigest;planDigest=$approved.planDigest;documents=$docs;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
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
    $request2=([pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=1;approvalVersion=$approved2.approvalVersion;baselineDigest=$approved2.baselineDigest;desiredDigest=$approved2.desiredDigest;planDigest=$approved2.planDigest;documents=$update;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    $done=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request2
    Assert-Equal 200 $done.StatusCode
    Assert-Equal 1 @((Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).documents.ipSets.items).Count
}

Invoke-TestCase -Name 'Simulator apply rejects stale revisions, forged digest, actor restrictions and live-shaped mutations' -Body {
    $data=Import-SimulatorTopology -Path $syntheticFixture
    $gateway=@($data.gateways | Where-Object { $_.domain -eq 'DomainB' -and $_.tier -eq 1 })[0]
    $current=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $approved=Get-SimulatorDraftPlan -Baseline $current -DesiredDocuments $current.documents
    $request=([pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=9;approvalVersion=$approved.approvalVersion;baselineDigest=$approved.baselineDigest;desiredDigest=$approved.desiredDigest;planDigest=$approved.planDigest;documents=$current.documents;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
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
        $request=([pscustomobject]@{gatewayId=$current.gatewayId;expectedRevision=0;approvalVersion=$approved.approvalVersion;baselineDigest=$approved.baselineDigest;desiredDigest=$approved.desiredDigest;planDigest=$approved.planDigest;documents=$current.documents;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'} | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
        Assert-Equal 200 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $request).StatusCode
        Assert-True ([IO.File]::Exists($persist))
        $reloaded=Initialize-SimulatorWorkspace -Dataset (Import-SimulatorTopology -Path $syntheticFixture) -PersistencePath $persist
        Assert-Equal 1 (Get-SimulatorWorkspaceState -Dataset $reloaded -GatewayId $current.gatewayId).revision
        [IO.File]::WriteAllText($persist,'{"schemaVersion":99}')
        Assert-Throws { Initialize-SimulatorWorkspace -Dataset (Import-SimulatorTopology -Path $syntheticFixture) -PersistencePath $persist }
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) } }
}

Invoke-TestCase -Name 'Simulator approval fingerprint matches across independent Windows PowerShell processes' -Body {
    $probe=Join-Path $ProjectRoot 'tests\Fixtures\SimulatorDigestProbe.ps1'
    $exe=Join-Path $PSHOME 'powershell.exe'
    Assert-True ([IO.File]::Exists($exe)) 'Windows PowerShell 5.1 must be available.'
    $hashes=@()
    foreach ($attempt in 1..3) {
        $output=@(& $exe -NoLogo -NoProfile -NonInteractive -File $probe -ProjectRoot $ProjectRoot 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ('Independent approval probe failed: '+($output -join ' ')) }
        $fingerprints=@($output | Where-Object { ([string]$_) -cmatch '^[0-9a-f]{64}$' })
        Assert-Equal 1 $fingerprints.Count 'Exactly one approval digest per isolated process.'
        $hashes+= [string]$fingerprints[0]
    }
    Assert-Equal $hashes[0] $hashes[1] 'Approval must be stable across process-specific hashtable hashing.'
    Assert-Equal $hashes[0] $hashes[2] 'Approval must be stable for the same reviewed change.'
}

Invoke-TestCase -Name 'Enterprise simulator applies a new firewall rule with the exact approved JSON payload' -Body {
    $fixture=Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json'
    $data=Import-SimulatorTopology -Path $fixture
    $gateway=@($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
    $baseline=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $docs=Copy-NetworkDocuments -Documents $baseline.documents
    $nextOrder=([int](($docs.edgeFirewallRules.items | Measure-Object -Property order -Maximum).Maximum))+1
    $item=[pscustomobject]@{
        key='manual-test';name='Manual Test';description='';order=$nextOrder
        action='ALLOW';enabled=$true;logging=$true
        sourceIpSets=@();destinationIpSets=@()
        services=@([pscustomobject]@{protocol='TCP';ports=@('443','1433')})
    }
    $desired=Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $item -Create
    $approved=Get-SimulatorDraftPlan -Baseline $baseline -DesiredDocuments $desired
    Assert-Equal 1 $approved.plan.summary.Create
    $request=[pscustomobject]@{
        gatewayId=$gateway.gatewayId; expectedRevision=$approved.expectedRevision
        approvalVersion=$approved.approvalVersion;baselineDigest=$approved.baselineDigest;desiredDigest=$approved.desiredDigest;planDigest=$approved.planDigest; documents=$approved.documents
        actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'
    }
    # Exercise the real POST wire representation, not the in-memory object.
    $wire=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 40 -Compress)
    $response=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' `
        -Authorization 'Bearer simulator-edit-only' -RequestBody $wire
    Assert-Equal 200 $response.StatusCode 'Matching rule change must not cause a false 409.'
    $updated=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    Assert-Equal ($baseline.revision+1) $updated.revision
    Assert-Equal 1 @($updated.documents.edgeFirewallRules.items | Where-Object { $_.key -ceq 'manual-test' }).Count

    # A genuinely changed draft with its former approval still MUST be blocked.
    $fresh=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $newDocs=Copy-NetworkDocuments -Documents $fresh.documents
    $newDocs.edgeFirewallRules.items[0].name='Approved version'
    $next=Get-SimulatorDraftPlan -Baseline $fresh -DesiredDocuments $newDocs
    $forged=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject ([pscustomobject]@{
        gatewayId=$gateway.gatewayId;expectedRevision=$next.expectedRevision
        approvalVersion=$next.approvalVersion;baselineDigest=$next.baselineDigest;desiredDigest=$next.desiredDigest;planDigest=$next.planDigest;documents=$newDocs
        actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'
    }) -Depth 40)
    $forged.documents.edgeFirewallRules.items[0].name='Unapproved modification'
    $denied=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' `
        -Authorization 'Bearer simulator-edit-only' -RequestBody $forged
    Assert-Equal 409 $denied.StatusCode 'A changed rule must not reuse another approval.'
    Assert-Equal $fresh.revision (Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).revision
}

Invoke-TestCase -Name 'Simulator approval v2 survives editor state JSON, worker payload, and POST JSON roundtrips' -Body {
    $fixture=Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json'
    $data=Import-SimulatorTopology -Path $fixture
    $gateway=@($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
    # GET /state serialises server workspace and the client rebuilds a dictionary.
    # The old tests passed un-serialised Get-SimulatorWorkspaceState directly.
    $serverBaseline=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $clientBaseline=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $serverBaseline -Depth 40)
    $clientBaseline.documents=[ordered]@{
        ipSets=$clientBaseline.documents.ipSets
        edgeFirewallRules=$clientBaseline.documents.edgeFirewallRules
        manualIpReservations=$clientBaseline.documents.manualIpReservations
    }
    $draft=Copy-NetworkDocuments -Documents $clientBaseline.documents
    $nextOrder=([int](($draft.edgeFirewallRules.items | Measure-Object -Property order -Maximum).Maximum))+1
    $rule=[pscustomobject]@{
        key='ui-cross-boundary';name='UI cross-boundary';description='';order=$nextOrder
        action='ALLOW';enabled=$true;logging=$true
        sourceIpSets=@();destinationIpSets=@()
        services=@([pscustomobject]@{protocol='TCP';ports=@('443','1433')})
    }
    $draft=Set-NetworkDraftItem -Documents $draft -ResourceKind edgeFirewallRules -Item $rule -Create
    $approved=Get-SimulatorDraftPlan -Baseline $clientBaseline -DesiredDocuments $draft
    Assert-Equal 2 $approved.approvalVersion
    Assert-Equal 1 $approved.plan.summary.Create
    # Simulate the data object carried through worker events and later HTTP JSON.
    $workerEvent=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $approved -Depth 45)
    $request=[pscustomobject]@{
        gatewayId=$workerEvent.plan.scope
        expectedRevision=$workerEvent.expectedRevision
        approvalVersion=$workerEvent.approvalVersion
        baselineDigest=$workerEvent.baselineDigest
        desiredDigest=$workerEvent.desiredDigest
        planDigest=$workerEvent.planDigest
        documents=$workerEvent.documents
        actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'
    }
    $wire=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 45)
    $result=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $wire
    Assert-Equal 200 $result.StatusCode 'GUI-shaped JSON path must accept the exact approved document.'
    Assert-Equal 1 (Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).revision
}

Invoke-TestCase -Name 'Simulator approval v2 rejects changed drafts, unapproved baselines and obsolete approval formats' -Body {
    $fixture=Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json'
    $data=Import-SimulatorTopology -Path $fixture
    $gateway=@($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
    $base=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $desired=Copy-NetworkDocuments -Documents $base.documents
    $desired.edgeFirewallRules.items[0].description='Review-approved value'
    $approved=Get-SimulatorDraftPlan -Baseline $base -DesiredDocuments $desired
    $request=[pscustomobject]@{
        gatewayId=$gateway.gatewayId;expectedRevision=$approved.expectedRevision
        approvalVersion=$approved.approvalVersion;baselineDigest=$approved.baselineDigest
        desiredDigest=$approved.desiredDigest;planDigest=$approved.planDigest
        documents=$approved.documents;actorDomain='DomainA';actorTier=0;confirmation='APPLY SIMULATOR'
    }
    $wire=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 40)
    $wire.documents.edgeFirewallRules.items[0].description='NOT reviewed'
    $res=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $wire
    Assert-Equal 409 $res.StatusCode 'Changing a field after approval must be rejected.'
    Assert-True ([string]$res.Body.error -like '*draft differs*')

    $old=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 40)
    $old.approvalVersion=1
    Assert-Equal 409 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $old).StatusCode

    # Change the synthetic server's current baseline without incrementing the
    # revision to simulate a malformed/externally replaced simulator state.
    $data.simulatorWorkspace[$gateway.gatewayId].documents.edgeFirewallRules.items[0].description='Externally changed baseline'
    $current=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 40)
    $res2=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $current
    Assert-Equal 409 $res2.StatusCode 'Changed server baseline must be rejected even when revision is unchanged.'
    Assert-True ([string]$res2.Body.error -like '*baseline differs*')
    Assert-Equal 0 (Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).revision
}

Invoke-TestCase -Name 'Simulator approval v3 applies UI Manual Test with Any services through frozen worker and HTTP JSON' -Body {
    $fixture=Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json'
    $data=Import-SimulatorTopology -Path $fixture
    $gateway=@($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
    $baseline=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $clientBaseline=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $baseline -Depth 40 -Compress)
    $clientBaseline.documents=[ordered]@{
        ipSets=$clientBaseline.documents.ipSets
        edgeFirewallRules=$clientBaseline.documents.edgeFirewallRules
        manualIpReservations=$clientBaseline.documents.manualIpReservations
    }
    $draft=Copy-NetworkDocuments -Documents $clientBaseline.documents
    $keys=@($draft.ipSets.items | ForEach-Object { [string]$_.key })
    Assert-True ($keys.Count -ge 2) 'Enterprise lab requires at least two IP Sets.'
    $nextOrder=([int](($draft.edgeFirewallRules.items | Measure-Object -Property order -Maximum).Maximum))+1
    $rule=[pscustomobject]@{
        key='manual-test';name='Manual Test';description='';order=$nextOrder
        action='ALLOW';enabled=$true;logging=$true
        sourceIpSets=@($keys[0]);destinationIpSets=@($keys[1]);services=@()
    }
    $draft=Set-NetworkDraftItem -Documents $draft -ResourceKind edgeFirewallRules -Item $rule -Create
    $approved=Get-SimulatorDraftPlan -Baseline $clientBaseline -DesiredDocuments $draft
    Assert-Equal 1 $approved.plan.summary.Create
    Assert-True (-not $approved.plan.blocked)
    Assert-Equal 64 ([string]$approved.frozenDesiredDigest).Length
    $event=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $approved -Depth 45 -Compress)
    # This is the simulator-only Apply request built by the production client:
    # docs stay a string, so a new runspace cannot re-serialize the rule arrays.
    $request=New-SimulatorApprovedApplyRequest -Approved $event -ActorDomain 'DomainA' -ActorTier 0
    Assert-Equal 3 $request.approvalVersion
    Assert-True ($null -eq $request.PSObject.Properties['documents']) 'v3 request must not transmit a second state object.'
    $wire=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 45 -Compress)
    Assert-Equal $event.frozenDocumentsJson $wire.documentsJson
    $response=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $wire
    Assert-Equal 200 $response.StatusCode 'UI-shaped Manual Test with Any services should apply.'
    $after=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    Assert-Equal 1 @($after.documents.edgeFirewallRules.items | Where-Object { $_.key -ceq 'manual-test' }).Count
    $savedRule=@($after.documents.edgeFirewallRules.items | Where-Object { $_.key -ceq 'manual-test' })[0]
    Assert-Equal 0 @($savedRule.services).Count
}

Invoke-TestCase -Name 'Simulator approval v3 fails closed for altered frozen draft ambiguous documents and stale approval' -Body {
    $data=Import-SimulatorTopology -Path (Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json')
    $gateway=@($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
    $baseline=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $draft=Copy-NetworkDocuments -Documents $baseline.documents
    $draft.edgeFirewallRules.items[0].description='Approved description'
    $approved=Get-SimulatorDraftPlan -Baseline $baseline -DesiredDocuments $draft
    $request=New-SimulatorApprovedApplyRequest -Approved $approved -ActorDomain 'DomainA' -ActorTier 0
    $altered=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 45)
    $altered.documentsJson=$altered.documentsJson.Replace('Approved description','Unapproved description')
    $denied=Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $altered
    Assert-Equal 409 $denied.StatusCode
    Assert-True ([string]$denied.Body.error -like '*draft differs*')
    $tamperedEvent=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $approved -Depth 45)
    $tamperedEvent.frozenDocumentsJson=$tamperedEvent.frozenDocumentsJson.Replace('Approved description','Unapproved description')
    Assert-Throws { New-SimulatorApprovedApplyRequest -Approved $tamperedEvent -ActorDomain 'DomainA' -ActorTier 0 }
    $mixed=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 45)
    $mixed | Add-Member -NotePropertyName documents -NotePropertyValue $draft
    Assert-Equal 409 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $mixed).StatusCode
    $stale=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 45)
    $stale.expectedRevision=99
    Assert-Equal 409 (Invoke-SimulatorRoute -Dataset $data -Method POST -Path '/__simulator/v1/apply' -Authorization 'Bearer simulator-edit-only' -RequestBody $stale).StatusCode
    Assert-Equal 0 (Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).revision
}

Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkRuleTemplates.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Access\SimulatorRbac.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
$fixture=Join-Path $ProjectRoot 'simulator\topology.json'
$catalogue=Join-Path $ProjectRoot 'templates\firewall-rules.json'

Invoke-TestCase -Name 'Search matches names IDs protocols and IP data without evaluating wildcard or regex input' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    Assert-Equal 1 @((Find-NetworkDraftItems -Documents $docs -ResourceKind edgeFirewallRules -Search ([string]$docs.edgeFirewallRules.items[0].name))).Count
    Assert-Equal 0 @((Find-NetworkDraftItems -Documents $docs -ResourceKind edgeFirewallRules -Search '[.*]')).Count
    Assert-Equal 1 @((Find-NetworkDraftItems -Documents $docs -ResourceKind ipSets -Search ([string]$docs.ipSets.items[0].addresses[0]))).Count
}

Invoke-TestCase -Name 'Firewall filters compose status and action without mutating the draft' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    $original=ConvertTo-Json $docs -Depth 30 -Compress
    Assert-Equal 1 @((Find-NetworkDraftItems -Documents $docs -ResourceKind edgeFirewallRules -Action ALLOW -Status Enabled)).Count
    Assert-Equal 0 @((Find-NetworkDraftItems -Documents $docs -ResourceKind edgeFirewallRules -Action DROP -Status Enabled)).Count
    Assert-Equal $original (ConvertTo-Json $docs -Depth 30 -Compress)
}

Invoke-TestCase -Name 'Bulk firewall updates are atomic preserve order and refuse unknown keys' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    $originalKey=[string]$docs.edgeFirewallRules.items[0].key
    $next=Set-NetworkDraftBulkRules -Documents $docs -Keys @($originalKey) -Action DROP -Status Disabled -Logging Off
    Assert-Equal 'DROP' $next.edgeFirewallRules.items[0].action
    Assert-True (-not $next.edgeFirewallRules.items[0].enabled)
    Assert-True (-not $next.edgeFirewallRules.items[0].logging)
    Assert-Equal 'ALLOW' $docs.edgeFirewallRules.items[0].action
    Assert-Throws { Set-NetworkDraftBulkRules -Documents $next -Keys @($originalKey,'missing') -Status Enabled }
    Assert-Throws { Set-NetworkDraftBulkRules -Documents $next -Keys @($originalKey) }
    Assert-Equal 0 $next.edgeFirewallRules.items[0].order
}

Invoke-TestCase -Name 'Bulk deletion blocks dangling IP Set references and does not touch baseline' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    $setKey=[string]$docs.ipSets.items[0].key
    Assert-Throws { Remove-NetworkDraftBulkItems -Documents $docs -ResourceKind ipSets -Keys @($setKey) }
    $ruleKey=[string]$docs.edgeFirewallRules.items[0].key
    $withoutRule=Remove-NetworkDraftBulkItems -Documents $docs -ResourceKind edgeFirewallRules -Keys @($ruleKey)
    $withoutSet=Remove-NetworkDraftBulkItems -Documents $withoutRule -ResourceKind ipSets -Keys @($setKey)
    Assert-Equal 0 @($withoutSet.ipSets.items).Count
    Assert-Equal 1 @($docs.ipSets.items).Count
}

Invoke-TestCase -Name 'Rule templates validate catalogue and create unique disabled draft rules' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    $templates=@(Get-NetworkRuleTemplates -Path $catalogue)
    Assert-Equal 3 $templates.Count
    $t=New-NetworkRuleFromTemplate -Documents $docs -Template $templates[0] -Name 'HTTPS Example'
    Assert-Equal 'https-example' $t.key
    Assert-Equal 443 ([int]$t.services[0].ports[0])
    Assert-True (-not $t.enabled) 'Templates must never create an enabled rule automatically.'
    $changed=Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $t -Create
    $duplicate=New-NetworkRuleFromTemplate -Documents $changed -Template $templates[0] -Name 'HTTPS Example'
    Assert-Equal 'https-example-2' $duplicate.key
    Assert-Equal 1 @($docs.edgeFirewallRules.items).Count
}

Invoke-TestCase -Name 'Synthetic RBAC grants only Tier 0 administrators apply and blocks reverse trust' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $admin=Get-SimulatorActorRole -Dataset $data -ActorDomain DomainA -ActorTier 0 -TargetDomain DomainB -TargetTier 1
    $editor=Get-SimulatorActorRole -Dataset $data -ActorDomain DomainB -ActorTier 1 -TargetDomain DomainB -TargetTier 1
    $viewer=Get-SimulatorActorRole -Dataset $data -ActorDomain DomainB -ActorTier 1 -TargetDomain DomainA -TargetTier 0
    Assert-Equal 'Administrator' $admin.Role
    Assert-Equal 'Editor' $editor.Role
    Assert-Equal 'Viewer' $viewer.Role
    Assert-True (Test-SimulatorRolePermission -Role $admin.Role -Operation Apply)
    Assert-True (Test-SimulatorRolePermission -Role $editor.Role -Operation Edit)
    Assert-True (-not (Test-SimulatorRolePermission -Role $editor.Role -Operation Apply))
    Assert-True (-not (Test-SimulatorRolePermission -Role $viewer.Role -Operation BulkEdit))
    Assert-True (Test-SimulatorRolePermission -Role $viewer.Role -Operation Monitor)
}

Invoke-TestCase -Name 'Simulator apply enforces RBAC on the server not only in WinForms' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $gateway=@($data.gateways | Where-Object {$_.domain -eq 'DomainB' -and $_.tier -eq 1})[0]
    $current=Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId
    $approved=Get-SimulatorDraftPlan -Baseline $current -DesiredDocuments $current.documents
    $request=[pscustomobject]@{gatewayId=$gateway.gatewayId;expectedRevision=0;planDigest=$approved.planDigest;documents=$current.documents;actorDomain='DomainB';actorTier=1;confirmation='APPLY SIMULATOR'}
    Assert-Throws { Invoke-SimulatorApply -Dataset $data -Request $request }
    Assert-Equal 0 (Get-SimulatorWorkspaceState -Dataset $data -GatewayId $gateway.gatewayId).revision
}

Invoke-TestCase -Name 'Bulk metadata updates IP Sets and reservations without changing addresses' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $docs=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents
    $key=[string]$docs.ipSets.items[0].key
    $updated=Set-NetworkDraftBulkDescription -Documents $docs -ResourceKind ipSets -Keys @($key) -Description 'New note'
    Assert-Equal 'New note' $updated.ipSets.items[0].description
    Assert-Equal $docs.ipSets.items[0].addresses[0] $updated.ipSets.items[0].addresses[0]
    Assert-True ([string]$docs.ipSets.items[0].description -cne 'New note')
    Assert-Throws { Set-NetworkDraftBulkDescription -Documents $docs -ResourceKind ipSets -Keys @($key,'missing') -Description 'Invalid batch' }
}

Invoke-TestCase -Name 'Engineers can save local reusable templates without copying scope IP Set bindings' -Body {
    $data=Import-SimulatorTopology -Path $fixture
    $rule=(Get-SimulatorWorkspaceState -Dataset $data -GatewayId $data.gateways[0].gatewayId).documents.edgeFirewallRules.items[0]
    $dir=Join-Path ([IO.Path]::GetTempPath()) ('vcd-templates-'+[guid]::NewGuid().ToString('n'))
    $path=Join-Path $dir 'user-templates.json'
    try {
        $result=Save-NetworkRuleTemplate -Path $path -Rule $rule -Name 'Custom DNS rule' -BuiltInPath $catalogue
        Assert-Equal 'custom-dns-rule' $result.key
        $all=@(Get-NetworkRuleTemplates -Path $catalogue -AdditionalPath $path)
        Assert-Equal 4 $all.Count
        $content=Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Assert-True (-not $content.Contains('sourceIpSets')) 'Template leaked source IP Set bindings'
        Assert-True (-not $content.Contains('destinationIpSets')) 'Template leaked destination IP Set bindings'
        Assert-Throws { Save-NetworkRuleTemplate -Path $path -Rule $rule -Name 'Custom DNS rule' -BuiltInPath $catalogue }
        Assert-Throws { Save-NetworkRuleTemplate -Path $path -Rule $rule -Name 'HTTPS' -BuiltInPath $catalogue }
    }
    finally { if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir,$true) } }
}

Import-Module (Join-Path $ProjectRoot 'src\Application\Planning\OfflinePlan.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Domain\Planning\Planning.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\State\StateRepository.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -Force

function Get-DemoView {
    param([string]$View)
    return (Read-NetworkStateView -StateRoot (Join-Path $ProjectRoot 'examples\demo-state') -Environment demo -Scope edge-gw-demo -View $View)
}
function Copy-TestView {
    param($View)
    # Return fresh independent objects, not references shared between test cases.
    $copy = [ordered]@{}
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $copy[$kind] = (ConvertTo-Json -InputObject $View.Documents[$kind] -Depth 30 | ConvertFrom-Json)
    }
    return [pscustomobject]@{ Available=$true; Documents=$copy }
}

Invoke-TestCase -Name 'Demo three-way plan gives deterministic summary and dependencies' -Body {
    $plan = Get-OfflineNetworkPlan -StateRoot (Join-Path $ProjectRoot 'examples\demo-state') -Environment demo -Scope edge-gw-demo
    Assert-Equal 3 $plan.summary.Create
    Assert-Equal 1 $plan.summary.Update
    Assert-Equal 0 $plan.summary.Move
    Assert-Equal 2 $plan.summary.Delete
    Assert-Equal 0 @($plan.drift).Count
    Assert-True (-not $plan.blocked)
    $ipSetCreate = @($plan.actions | Where-Object { $_.ResourceKind -eq 'ipSets' -and $_.Key -eq 'monitor' })[0]
    $firewallCreate = @($plan.actions | Where-Object { $_.ResourceKind -eq 'edgeFirewallRules' -and $_.Key -eq 'allow-monitoring' })[0]
    Assert-Equal 'Create' $ipSetCreate.Change
    Assert-Equal 'Create' $firewallCreate.Change
    Assert-True ($firewallCreate.DependsOn -contains 'ipSets/monitor')
    Assert-True ([array]::IndexOf($plan.actions, $ipSetCreate) -lt [array]::IndexOf($plan.actions, $firewallCreate))
    Assert-Equal 'Delete' (@($plan.actions | Where-Object { $_.Key -eq 'legacy' })[0]).Change
}

Invoke-TestCase -Name 'Repeated planner invocations are deterministic with no timestamp in plan data' -Body {
    $p1 = Get-OfflineNetworkPlan -StateRoot (Join-Path $ProjectRoot 'examples\demo-state') -Environment demo -Scope edge-gw-demo
    $p2 = Get-OfflineNetworkPlan -StateRoot (Join-Path $ProjectRoot 'examples\demo-state') -Environment demo -Scope edge-gw-demo
    Assert-Equal (ConvertTo-Json -InputObject $p1 -Depth 30 -Compress) (ConvertTo-Json -InputObject $p2 -Depth 30 -Compress)
}

Invoke-TestCase -Name 'Missing observed baseline produces blocked preview rather than assumed empty network' -Body {
    $plan = New-NetworkChangePlan -Desired (Get-DemoView desired) -Applied (Get-DemoView applied) -Environment demo -Scope edge-gw-demo
    Assert-True $plan.blocked
    Assert-True (-not $plan.observedAvailable)
    Assert-True (@($plan.warnings).Count -ge 1)
    Assert-Equal 3 $plan.summary.Create
}

Invoke-TestCase -Name 'Missing applied state never deletes unmanaged objects from observed network' -Body {
    $desired = Get-DemoView desired
    $observed = Get-DemoView observed
    $plan = New-NetworkChangePlan -Desired $desired -Observed $observed -Environment demo -Scope edge-gw-demo
    Assert-True $plan.blocked
    Assert-Equal 0 $plan.summary.Delete
}

Invoke-TestCase -Name 'Externally modified managed resource is recognised as drift and blocked' -Body {
    $observed = Copy-TestView (Get-DemoView observed)
    $observed.Documents['ipSets'].items[0].addresses = @('10.10.1.99')
    $plan = New-NetworkChangePlan -Desired (Get-DemoView desired) -Applied (Get-DemoView applied) -Observed $observed -Environment demo -Scope edge-gw-demo
    Assert-True $plan.blocked
    Assert-Equal 'ExternallyModified' (@($plan.drift | Where-Object { $_.Key -eq 'web' })[0]).Change
}

Invoke-TestCase -Name 'Observed unmanaged key collision blocks proposed creation' -Body {
    $observed = Copy-TestView (Get-DemoView observed)
    $observed.Documents['ipSets'].items += [pscustomobject]@{ key='monitor'; name='Externally created'; addresses=@('10.10.8.1') }
    $plan = New-NetworkChangePlan -Desired (Get-DemoView desired) -Applied (Get-DemoView applied) -Observed $observed -Environment demo -Scope edge-gw-demo
    Assert-True $plan.blocked
    Assert-True (@($plan.drift | Where-Object { $_.Change -eq 'UnmanagedKeyCollision' }).Count -eq 1)
}

Invoke-TestCase -Name 'Pure firewall rule position change becomes Move not Update' -Body {
    $desired = Copy-TestView (Get-DemoView applied)
    $desired.Documents['edgeFirewallRules'].items[0].order = 20
    $desired.Documents['edgeFirewallRules'].items[1].order = 10
    $plan = New-NetworkChangePlan -Desired $desired -Applied (Get-DemoView applied) -Observed (Get-DemoView observed) -Environment demo -Scope edge-gw-demo
    Assert-Equal 2 $plan.summary.Move
    Assert-Equal 0 $plan.summary.Update
    Assert-Equal 0 $plan.summary.Delete
    Assert-Equal 0 $plan.summary.Create
}

Invoke-TestCase -Name 'Plan refuses dangling firewall group reference' -Body {
    $desired = Copy-TestView (Get-DemoView desired)
    $desired.Documents['edgeFirewallRules'].items[0].sourceIpSets = @('missing-ip-set')
    Assert-Throws { New-NetworkChangePlan -Desired $desired -Applied (Get-DemoView applied) -Observed (Get-DemoView observed) -Environment demo -Scope edge-gw-demo }
}

Invoke-TestCase -Name 'Plan refuses duplicate reservation of same IP on same network' -Body {
    $desired = Copy-TestView (Get-DemoView desired)
    $desired.Documents['manualIpReservations'].items += [pscustomobject]@{key='duplicate';networkId='org-vdc-network-demo';address='10.10.50.12'}
    Assert-Throws { New-NetworkChangePlan -Desired $desired -Applied (Get-DemoView applied) -Observed (Get-DemoView observed) -Environment demo -Scope edge-gw-demo }
}

Invoke-TestCase -Name 'Offline reports write parseable JSON and HTML with encoded unsafe text' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vcd-reports-' + [guid]::NewGuid().ToString('n'))
    try {
        $plan = Get-OfflineNetworkPlan -StateRoot (Join-Path $ProjectRoot 'examples\demo-state') -Environment demo -Scope edge-gw-demo
        # Inject a deliberately unsafe name into this report-only copy to verify HTML encoding.
        $plan.actions[0].After.name = '<script>alert("x")</script> & "friends"'
        $files = Export-OfflineNetworkPlan -Plan $plan -OutputDirectory $scratch -BaseName 'test-plan'
        Assert-True ([IO.File]::Exists($files.Json))
        Assert-True ([IO.File]::Exists($files.Html))
        $roundtrip = Get-Content -LiteralPath $files.Json -Raw | ConvertFrom-Json
        Assert-Equal 6 @($roundtrip.actions).Count
        $html = [IO.File]::ReadAllText($files.Html)
        Assert-True ($html.Contains('&lt;script&gt;')) 'HTML must encode untrusted state names'
        Assert-True ($html.Contains('&amp;')) 'HTML must encode ampersands in untrusted names'
        Assert-True ($html.Contains('&quot;friends&quot;')) 'HTML must encode quotes in untrusted names'
        Assert-True (-not $html.Contains('<script>')) 'No raw script from state data'
        Assert-Throws { Export-OfflineNetworkPlan -Plan $plan -OutputDirectory $scratch -BaseName '../escape' }
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) } }
}

Invoke-TestCase -Name 'Identical desired applied and observed views produce an empty no-op plan' -Body {
    $baseline = Get-DemoView applied
    $plan = New-NetworkChangePlan -Desired $baseline -Applied $baseline -Observed $baseline -Environment demo -Scope edge-gw-demo
    Assert-Equal 0 @($plan.actions).Count
    Assert-Equal 0 @($plan.drift).Count
    Assert-True (-not $plan.blocked)
}

Invoke-TestCase -Name 'Unmanaged observed-only objects are not scheduled for deletion' -Body {
    $observed = Copy-TestView (Get-DemoView observed)
    $observed.Documents['ipSets'].items += [pscustomobject]@{key='outside-tool';name='External Group';addresses=@('10.99.0.1')}
    $plan = New-NetworkChangePlan -Desired (Get-DemoView desired) -Applied (Get-DemoView applied) -Observed $observed -Environment demo -Scope edge-gw-demo
    Assert-Equal 0 @($plan.actions | Where-Object { $_.Key -eq 'outside-tool' }).Count
    Assert-Equal 0 @($plan.drift | Where-Object { $_.Key -eq 'outside-tool' }).Count
}

Invoke-TestCase -Name 'Missing managed rule in observed state blocks the plan' -Body {
    $observed = Copy-TestView (Get-DemoView observed)
    $observed.Documents['edgeFirewallRules'].items = @($observed.Documents['edgeFirewallRules'].items | Where-Object { $_.key -ne 'legacy-access' })
    $plan = New-NetworkChangePlan -Desired (Get-DemoView desired) -Applied (Get-DemoView applied) -Observed $observed -Environment demo -Scope edge-gw-demo
    Assert-True $plan.blocked
    Assert-Equal 'MissingFromObserved' (@($plan.drift | Where-Object { $_.Key -eq 'legacy-access' })[0]).Change
}

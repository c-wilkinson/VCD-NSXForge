Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -Force
$topologyPath = Join-Path $ProjectRoot 'simulator\topology.json'

Invoke-TestCase -Name 'Simulator models DomainA as trusted by B and C without trusting them back' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    Assert-Equal 3 $top.domains.Count
    Assert-Equal 6 $top.gateways.Count
    Assert-Equal 0 @($top.domains[0].trustedIdentityDomains).Count
    Assert-Equal 'DomainA' $top.domains[1].trustedIdentityDomains[0]
    Assert-Equal 'DomainA' $top.domains[2].trustedIdentityDomains[0]
    Assert-Equal 2 $top.managementGrants.Count
}

Invoke-TestCase -Name 'DomainA identities can authenticate to DomainB and DomainC but never inversely' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    foreach ($to in @('DomainB','DomainC')) {
        $forward = Get-SimulatorAccessDecision -Dataset $top -SourceDomain DomainA -SourceTier 0 -TargetDomain $to -TargetTier 1
        Assert-True $forward.authenticationPossible
        $inverse = Get-SimulatorAccessDecision -Dataset $top -SourceDomain $to -SourceTier 0 -TargetDomain DomainA -TargetTier 1
        Assert-True (-not $inverse.authenticationPossible)
        Assert-True (-not $inverse.canManage)
    }
}

Invoke-TestCase -Name 'DomainB and DomainC do not authenticate across their boundary' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    foreach ($a in @(@('DomainB','DomainC'),@('DomainC','DomainB'))) {
        $decision = Get-SimulatorAccessDecision -Dataset $top -SourceDomain $a[0] -SourceTier 0 -TargetDomain $a[1] -TargetTier 1
        Assert-True (-not $decision.authenticationPossible)
        Assert-True (-not $decision.canManage)
    }
}

Invoke-TestCase -Name 'Tier 0 may administer Tier 1 when authorized; Tier 1 may never administer Tier 0' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    foreach ($domain in @('DomainA','DomainB','DomainC')) {
        $allowed = Get-SimulatorAccessDecision -Dataset $top -SourceDomain $domain -SourceTier 0 -TargetDomain $domain -TargetTier 1
        $blocked = Get-SimulatorAccessDecision -Dataset $top -SourceDomain $domain -SourceTier 1 -TargetDomain $domain -TargetTier 0
        Assert-True $allowed.canManage
        Assert-True (-not $blocked.canManage)
        Assert-True (-not $blocked.tierPermitsManagement)
    }
}

Invoke-TestCase -Name 'Cross-domain management needs explicit delegation in addition to trust and tier' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    foreach ($target in @('DomainB','DomainC')) {
        $allowed = Get-SimulatorAccessDecision -Dataset $top -SourceDomain DomainA -SourceTier 0 -TargetDomain $target -TargetTier 1
        Assert-True $allowed.canManage
        $notDelegated = Get-SimulatorAccessDecision -Dataset $top -SourceDomain DomainA -SourceTier 1 -TargetDomain $target -TargetTier 1
        Assert-True $notDelegated.authenticationPossible
        Assert-True $notDelegated.tierPermitsManagement
        Assert-True (-not $notDelegated.delegatedManagement)
        Assert-True (-not $notDelegated.canManage)
        $privileged = Get-SimulatorAccessDecision -Dataset $top -SourceDomain DomainA -SourceTier 0 -TargetDomain $target -TargetTier 0
        Assert-True (-not $privileged.canManage)
    }
}

Invoke-TestCase -Name 'Topology validation rejects accidentally reversed trust or unexpected domains' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    $top.domains[0].trustedIdentityDomains = @('DomainB')
    Assert-Throws { Test-SimulatorTopology -Dataset $top }
    $top = Import-SimulatorTopology -Path $topologyPath
    $top.domains[1].trustedIdentityDomains = @('DomainC')
    Assert-Throws { Test-SimulatorTopology -Dataset $top }
    $top = Import-SimulatorTopology -Path $topologyPath
    $top.gateways[0].domain = 'Unknown'
    Assert-Throws { Test-SimulatorTopology -Dataset $top }
}

Invoke-TestCase -Name 'Unknown domain and invalid tier do not produce an allowed access decision' -Body {
    $top = Import-SimulatorTopology -Path $topologyPath
    Assert-Throws { Get-SimulatorAccessDecision -Dataset $top -SourceDomain DomainX -SourceTier 0 -TargetDomain DomainA -TargetTier 0 }
    Assert-Throws { Get-SimulatorAccessDecision -Dataset $top -SourceDomain DomainA -SourceTier 2 -TargetDomain DomainB -TargetTier 1 }
}

# A synthetic representation of authentication trust, security tiers and delegated administration.
# NOT a substitute for AD permissions or VMware NSX access-control evaluation.
Set-StrictMode -Version Latest

function Import-SimulatorTopology {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dataset = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-SimulatorTopology -Dataset $dataset
    return $dataset
}

function Test-SimulatorTopology {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset)
    if ($Dataset.schemaVersion -ne 1 -or $Dataset.synthetic -cne $true) { throw 'Simulator dataset must be explicitly marked synthetic with schemaVersion 1.' }
    $names = @($Dataset.domains | ForEach-Object { [string]$_.name })
    if (($names -join ',') -cne 'DomainA,DomainB,DomainC') { throw 'Expected ordered DomainA, DomainB, DomainC definitions.' }
    foreach ($domain in $Dataset.domains) {
        $trusts = @($domain.trustedIdentityDomains)
        if ($domain.name -eq 'DomainA' -and $trusts.Count -ne 0) { throw 'DomainA must trust no other domain.' }
        if ($domain.name -ne 'DomainA' -and ($trusts.Count -ne 1 -or $trusts[0] -cne 'DomainA')) { throw "$($domain.name) must trust DomainA only." }
        if (@($domain.tiers | ForEach-Object { $_.id }) -join ',' -cne '0,1') { throw 'Each domain must define both Tier 0 and Tier 1.' }
    }
    $gatewayIds = @{}
    $networkIds = @{}
    foreach ($gateway in @($Dataset.gateways)) {
        if ($gateway.domain -cnotin $names -or $gateway.tier -notin @(0,1) -or
            $gateway.gatewayId -cnotmatch '^urn:vcloud:gateway:[0-9a-f-]{36}$' -or
            $gateway.networkId -cnotmatch '^urn:vcloud:network:[0-9a-f-]{36}$') {
            throw 'Invalid simulator gateway scope.'
        }
        if ($gatewayIds.ContainsKey([string]$gateway.gatewayId) -or $networkIds.ContainsKey([string]$gateway.networkId)) { throw 'Duplicate gateway or network URN.' }
        $gatewayIds[[string]$gateway.gatewayId] = $true
        $networkIds[[string]$gateway.networkId] = $true
    }
    if ($gatewayIds.Count -ne 6) { throw 'Simulator requires exactly one gateway per domain/tier.' }
    foreach ($grant in @($Dataset.managementGrants)) {
        if ($grant.sourceDomain -cne 'DomainA' -or $grant.sourceTier -ne 0 -or $grant.targetDomain -cnotin @('DomainB','DomainC') -or $grant.targetTier -ne 1 -or $grant.action -cne 'Manage') {
            throw 'Unsupported synthetic management delegation.'
        }
    }
}

function Get-SimulatorAccessDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,
          [Parameter(Mandatory)][string]$SourceDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$SourceTier,
          [Parameter(Mandatory)][string]$TargetDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$TargetTier)
    $source = @($Dataset.domains | Where-Object { $_.name -ceq $SourceDomain })
    $target = @($Dataset.domains | Where-Object { $_.name -ceq $TargetDomain })
    if ($source.Count -ne 1 -or $target.Count -ne 1) { throw 'Unknown domain in access evaluation.' }
    # Trust is inbound to the TARGET: "DomainB trusts DomainA" means A can authenticate to B.
    $authenticated = ($SourceDomain -ceq $TargetDomain -or @($target[0].trustedIdentityDomains) -ccontains $SourceDomain)
    $tierPermits = ($SourceTier -le $TargetTier)
    $delegated = $false
    if ($SourceDomain -ceq $TargetDomain) { $delegated = $true }
    else {
        foreach ($grant in @($Dataset.managementGrants)) {
            if ($grant.sourceDomain -ceq $SourceDomain -and $grant.sourceTier -eq $SourceTier -and
                $grant.targetDomain -ceq $TargetDomain -and $grant.targetTier -eq $TargetTier -and $grant.action -ceq 'Manage') {
                $delegated = $true
                break
            }
        }
    }
    $reasons = @()
    if (-not $authenticated) { $reasons += 'Target domain does not trust the source identity domain.' }
    if (-not $tierPermits) { $reasons += 'Tier 1 cannot manage Tier 0.' }
    if (-not $delegated) { $reasons += 'No synthetic management delegation exists.' }
    if ($reasons.Count -eq 0) { $reasons = @('Synthetic policy permits this management direction.') }
    [pscustomobject]@{
        sourceDomain=$SourceDomain; sourceTier=$SourceTier; targetDomain=$TargetDomain; targetTier=$TargetTier
        authenticationPossible=[bool]$authenticated; tierPermitsManagement=[bool]$tierPermits
        delegatedManagement=[bool]$delegated; canManage=[bool]($authenticated -and $tierPermits -and $delegated)
        reasons=@($reasons)
    }
}

Export-ModuleMember -Function Import-SimulatorTopology, Test-SimulatorTopology, Get-SimulatorAccessDecision

# In-memory, non-authoritative inventory for a verified VCD tenant context.
# Nothing in this module writes configuration, reports or live VCD state.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\VcdApi\VcdApi.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Access\VcdAuthorization.psm1') -ErrorAction Stop

function Get-VcdDiscoveryProperty {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return $Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-VcdDiscoveryReferenceId {
    param($Value)
    if ($Value -is [string]) { return [string]$Value }
    return [string](Get-VcdDiscoveryProperty -Value $Value -Name 'id')
}

function ConvertTo-VcdDiscoveryEntry {
    param([Parameter(Mandatory)]$Resource, [Parameter(Mandatory)][string]$Type,
          [string]$OrgId='', [string]$VdcId='', [string]$GatewayId='')
    $id = [string](Get-VcdDiscoveryProperty $Resource 'id')
    $name = [string](Get-VcdDiscoveryProperty $Resource 'name')
    $resourceType = if ($Type -eq 'Network') { [string](Get-VcdDiscoveryProperty $Resource 'networkType') } else { '' }
    if ($Type -eq 'Gateway') { $resourceType = [string](Get-VcdDiscoveryProperty $Resource 'deploymentMode') }
    [pscustomobject]@{
        Id = $id; Name = $name; Kind = $Type; OrgId = $OrgId
        VdcId = $VdcId; GatewayId = $GatewayId; Type = $resourceType
        # Names never select resources. All relationships use immutable IDs.
        Label = ('{0} [{1}]' -f $name, $id)
    }
}

function Get-VcdDiscoveryInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)]$Identity,
          [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    if (-not $Identity.TargetOrgId -or -not $Identity.SessionId) { throw 'VCD discovery requires a verified session and target organisation.' }
    $CancellationToken.ThrowIfCancellationRequested()
    # Fetch complete pages for each collection before publishing any result.
    # 403, 429, 5xx, inconsistent pages or cancellation must not look like empty inventories.
    $rawOrgs = @(Get-VcdDiscoveryCollection -Client $Client -Kind orgs -CancellationToken $CancellationToken)
    $rawVdcs = @(Get-VcdDiscoveryCollection -Client $Client -Kind vdcs -CancellationToken $CancellationToken)
    $rawGateways = @(Get-VcdDiscoveryCollection -Client $Client -Kind edgeGateways -CancellationToken $CancellationToken)
    $rawNetworks = @(Get-VcdDiscoveryCollection -Client $Client -Kind orgVdcNetworks -CancellationToken $CancellationToken)
    $CancellationToken.ThrowIfCancellationRequested()

    $orgs = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $rawOrgs) {
        if ([string]$item.id -ceq [string]$Identity.TargetOrgId) {
            $orgs.Add((ConvertTo-VcdDiscoveryEntry -Resource $item -Type Organisation -OrgId ([string]$item.id)))
        }
    }
    if ($orgs.Count -ne 1) { throw 'VCD discovery incomplete: verified target organisation is not visible in the inventory.' }

    $vdcs = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $rawVdcs) {
        $orgId = Get-VcdOrgReference -Object $item
        if (-not $orgId) { throw 'VCD discovery incomplete: VDC ownership is unavailable.' }
        if ($orgId -cne $Identity.TargetOrgId) { continue }
        $vdcs.Add((ConvertTo-VcdDiscoveryEntry -Resource $item -Type Vdc -OrgId $orgId))
    }
    $visibleVdcIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $vdcs) { [void]$visibleVdcIds.Add($item.Id) }

    $gateways = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $rawGateways) {
        $orgId = Get-VcdOrgReference -Object $item
        if (-not $orgId) { throw 'VCD discovery incomplete: gateway ownership is unavailable.' }
        if ($orgId -cne $Identity.TargetOrgId) { continue }
        $vdcId = Get-VcdDiscoveryReferenceId (Get-VcdDiscoveryProperty $item 'orgVdc')
        if ($vdcId -and -not $visibleVdcIds.Contains($vdcId)) {
            # A gateway can be group-owned or exposed without access to its VDC;
            # retain the real parent ID instead of inventing an association.
            $vdcId = ''
        }
        $gateways.Add((ConvertTo-VcdDiscoveryEntry -Resource $item -Type Gateway -OrgId $orgId -VdcId $vdcId))
    }
    $gatewayIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $gateways) { [void]$gatewayIds.Add($item.Id) }

    $networks = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $rawNetworks) {
        $orgId = Get-VcdOrgReference -Object $item
        if (-not $orgId) { throw 'VCD discovery incomplete: network ownership is unavailable.' }
        if ($orgId -cne $Identity.TargetOrgId) { continue }
        $vdcId = Get-VcdDiscoveryReferenceId (Get-VcdDiscoveryProperty $item 'orgVdc')
        $connection = Get-VcdDiscoveryProperty $item 'connection'
        $gatewayId = Get-VcdDiscoveryReferenceId (Get-VcdDiscoveryProperty $connection 'routerRef')
        if ($gatewayId -and -not $gatewayIds.Contains($gatewayId)) {
            # Keep unattached/unknown gateway explicit, not silently associated
            # with a similarly named gateway elsewhere.
            $gatewayId = ''
        }
        $networks.Add((ConvertTo-VcdDiscoveryEntry -Resource $item -Type Network -OrgId $orgId -VdcId $vdcId -GatewayId $gatewayId))
    }
    $CancellationToken.ThrowIfCancellationRequested()
    return [pscustomobject]@{
        Complete = $true
        Visibility = 'PermissionScoped' # Complete enumeration of what this session can see, NOT proof that other objects do not exist.
        TargetOrgId = [string]$Identity.TargetOrgId
        Organisations = @($orgs.ToArray() | Sort-Object Name, Id)
        Vdcs = @($vdcs.ToArray() | Sort-Object Name, Id)
        Gateways = @($gateways.ToArray() | Sort-Object Name, Id)
        Networks = @($networks.ToArray() | Sort-Object Name, Id)
    }
}

Export-ModuleMember -Function Get-VcdDiscoveryInventory

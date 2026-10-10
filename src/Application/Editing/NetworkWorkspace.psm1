# Deterministic, presentation-independent resource searching and atomic bulk edits.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Planning\Planning.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\StateModel.psm1') -ErrorAction Stop

function Find-NetworkDraftItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][ValidateSet('edgeFirewallRules','ipSets','manualIpReservations')][string]$ResourceKind,
          [string]$Search='',
          [ValidateSet('All','ALLOW','DROP','REJECT')][string]$Action='All',
          [ValidateSet('All','Enabled','Disabled')][string]$Status='All')
    $items = @($Documents[$ResourceKind].items)
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($ResourceKind -eq 'edgeFirewallRules') {
            if ($Action -ne 'All' -and [string]$item.action -cne $Action) { continue }
            if ($Status -eq 'Enabled' -and -not [bool]$item.enabled) { continue }
            if ($Status -eq 'Disabled' -and [bool]$item.enabled) { continue }
        }
        if (-not [string]::IsNullOrWhiteSpace($Search)) {
            # Fixed-string search: do not interpret engineer input as regex or script.
            $pieces = [System.Collections.Generic.List[string]]::new()
            foreach ($property in @('key','name','description','action','address','networkId')) {
                $prop = $item.PSObject.Properties[$property]
                if ($null -ne $prop -and $null -ne $prop.Value) { $pieces.Add([string]$prop.Value) }
            }
            foreach ($property in @('addresses','sourceIpSets','destinationIpSets','services')) {
                $prop = $item.PSObject.Properties[$property]
                if ($null -ne $prop -and $null -ne $prop.Value) {
                    $pieces.Add((ConvertTo-Json -InputObject $prop.Value -Depth 10 -Compress))
                }
            }
            $haystack = $pieces -join ' '
            if ($haystack.IndexOf($Search.Trim(),[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $matched.Add($item)
    }
    if ($ResourceKind -eq 'edgeFirewallRules') { return @($matched.ToArray() | Sort-Object order) }
    return $matched.ToArray()
}

function Set-NetworkDraftBulkRules {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][string[]]$Keys,
          [ValidateSet('Keep','ALLOW','DROP','REJECT')][string]$Action='Keep',
          [ValidateSet('Keep','Enabled','Disabled')][string]$Status='Keep',
          [ValidateSet('Keep','On','Off')][string]$Logging='Keep')
    $unique = @($Keys | Select-Object -Unique)
    if ($unique.Count -lt 1 -or $unique.Count -ne $Keys.Count) { throw 'Select unique firewall rules to bulk edit.' }
    if ($Action -eq 'Keep' -and $Status -eq 'Keep' -and $Logging -eq 'Keep') { throw 'No changes requested.' }
    $clone = Copy-NetworkDocuments -Documents $Documents
    foreach ($key in $unique) {
        $found=@($clone.edgeFirewallRules.items | Where-Object { $_.key -ceq $key })
        if ($found.Count -ne 1) { throw "Firewall rule '$key' not found; bulk edit cancelled." }
        if ($Action -ne 'Keep') { $found[0].action=$Action }
        if ($Status -ne 'Keep') { $found[0].enabled=($Status -eq 'Enabled') }
        if ($Logging -ne 'Keep') { $found[0].logging=($Logging -eq 'On') }
    }
    $null=Test-NetworkStateView -Documents $clone
    return $clone
}

function Remove-NetworkDraftBulkItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][ValidateSet('edgeFirewallRules','ipSets','manualIpReservations')][string]$ResourceKind,
          [Parameter(Mandatory)][string[]]$Keys)
    $unique=@($Keys | Select-Object -Unique)
    if ($unique.Count -lt 1 -or $unique.Count -ne $Keys.Count) { throw 'Select unique resources to remove.' }
    $clone=Copy-NetworkDocuments -Documents $Documents
    foreach ($key in $unique) {
        if (@($clone[$ResourceKind].items | Where-Object { $_.key -ceq $key }).Count -ne 1) { throw "Resource '$key' not found; no changes made." }
    }
    $clone[$ResourceKind].items=@($clone[$ResourceKind].items | Where-Object { $_.key -cnotin $unique })
    if ($ResourceKind -eq 'edgeFirewallRules') {
        $i=0
        foreach ($rule in @($clone.edgeFirewallRules.items | Sort-Object order)) { $rule.order=$i; $i++ }
    }
    # Referential integrity errors abort the entire batch.
    $null=Test-NetworkStateView -Documents $clone
    return $clone
}

function Set-NetworkDraftBulkDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][ValidateSet('ipSets','manualIpReservations')][string]$ResourceKind,
          [Parameter(Mandatory)][string[]]$Keys,
          [AllowEmptyString()][string]$Description='')
    $unique=@($Keys | Select-Object -Unique)
    if ($unique.Count -lt 1 -or $unique.Count -ne $Keys.Count) { throw 'Select unique resources to edit.' }
    $clone=Copy-NetworkDocuments -Documents $Documents
    foreach ($key in $unique) {
        $matching=@($clone[$ResourceKind].items | Where-Object { $_.key -ceq $key })
        if ($matching.Count -ne 1) { throw "Resource '$key' not found; no changes made." }
        $matching[0].description=$Description
    }
    $null=Test-NetworkStateView -Documents $clone
    return $clone
}

Export-ModuleMember -Function Find-NetworkDraftItems, Set-NetworkDraftBulkRules, Remove-NetworkDraftBulkItems, Set-NetworkDraftBulkDescription

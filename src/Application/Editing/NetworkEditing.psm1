# Draft editor operations are pure and contain no HTTP, disk or WinForms calls.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Planning\Planning.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\StateModel.psm1') -ErrorAction Stop

function Copy-NetworkDocuments {
    param([Parameter(Mandatory)]$Documents)
    $clone = [ordered]@{}
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $clone[$kind] = (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Documents[$kind] -Depth 40))
    }
    return $clone
}

function Set-NetworkDraftItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][ValidateSet('ipSets','edgeFirewallRules','manualIpReservations')][string]$ResourceKind,
          [Parameter(Mandatory)]$Item,
          [switch]$Create)
    $candidate = Copy-NetworkDocuments -Documents $Documents
    $existing = @($candidate[$ResourceKind].items | Where-Object { $_.key -ceq $Item.key })
    if ($Create -and $existing.Count -gt 0) { throw "Logical key '$($Item.key)' already exists." }
    if (-not $Create -and $existing.Count -ne 1) { throw "Logical key '$($Item.key)' does not exist." }
    $remaining = @($candidate[$ResourceKind].items | Where-Object { $_.key -cne $Item.key })
    $candidate[$ResourceKind].items = @($remaining + @($Item))
     $null=Test-NetworkStateView -Documents $candidate
    return $candidate
}

function Remove-NetworkDraftItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][ValidateSet('ipSets','edgeFirewallRules','manualIpReservations')][string]$ResourceKind,
          [Parameter(Mandatory)][string]$Key)
    $candidate = Copy-NetworkDocuments -Documents $Documents
    if (@($candidate[$ResourceKind].items | Where-Object { $_.key -ceq $Key }).Count -ne 1) { throw "Resource '$Key' not found." }
    $candidate[$ResourceKind].items = @($candidate[$ResourceKind].items | Where-Object { $_.key -cne $Key })
     $null=Test-NetworkStateView -Documents $candidate
    return $candidate
}

function Move-NetworkDraftRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents, [Parameter(Mandatory)][string]$Key,
          [Parameter(Mandatory)][ValidateSet('Up','Down')][string]$Direction)
    $candidate = Copy-NetworkDocuments -Documents $Documents
    $items = @($candidate['edgeFirewallRules'].items | Sort-Object order)
    $position = -1
    for ($i=0; $i -lt $items.Count; $i++) { if ($items[$i].key -ceq $Key) { $position=$i; break } }
    if ($position -lt 0) { throw "Rule '$Key' not found." }
    $other = if ($Direction -eq 'Up') { $position - 1 } else { $position + 1 }
    if ($other -lt 0 -or $other -ge $items.Count) { return $candidate }
    $old = [int]$items[$position].order
    $items[$position].order = [int]$items[$other].order
    $items[$other].order = $old
    $candidate['edgeFirewallRules'].items = @($items | Sort-Object order)
     $null=Test-NetworkStateView -Documents $candidate
    return $candidate
}

function New-SimulatorDocumentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$DesiredDocuments,
          [Parameter(Mandatory)]$CurrentDocuments,
          [Parameter(Mandatory)][string]$Scope)
    $desired = [pscustomobject]@{ Available=$true; Documents=$DesiredDocuments }
    $current = [pscustomobject]@{ Available=$true; Documents=$CurrentDocuments }
    # In the local simulator, applied and observed are the same server revision.
    return New-NetworkChangePlan -Desired $desired -Applied $current -Observed $current -Environment 'simulator' -Scope $Scope
}

Export-ModuleMember -Function Copy-NetworkDocuments, Set-NetworkDraftItem, Remove-NetworkDraftItem, Move-NetworkDraftRule, New-SimulatorDocumentPlan

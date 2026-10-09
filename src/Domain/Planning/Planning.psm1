# Offline-only three-way plan. No disk, HTTP, UI, or deployment code.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\State\StateModel.psm1') -Force

function Get-NetworkDocumentIndex {
    param($Document)
    $result = @{}
    foreach ($item in @($Document.items)) { $result[[string]$item.key] = $item }
    return $result
}

function Confirm-NetworkStateViewModel {
    param($View)
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        if (-not $View.Documents.Contains($kind)) { throw "Required state kind '$kind' not present." }
        $doc = $View.Documents[$kind]
        Confirm-NetworkDocument -Document $doc
        if ($doc.resourceKind -cne $kind) { throw "Wrong state kind in '$kind' document." }
    }
    $sets = Get-NetworkDocumentIndex -Document $View.Documents['ipSets']
    foreach ($rule in @($View.Documents['edgeFirewallRules'].items)) {
        foreach ($key in @($rule.sourceIpSets) + @($rule.destinationIpSets)) {
            if (-not $sets.ContainsKey([string]$key)) { throw "Rule '$($rule.key)' references missing IP Set '$key'." }
        }
    }
    $seenIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($reservation in @($View.Documents['manualIpReservations'].items)) {
        $identity = '{0}/{1}' -f $reservation.networkId, $reservation.address
        if (-not $seenIps.Add($identity)) { throw "Duplicate IP reservation '$identity'." }
    }
}

function New-NetworkChangePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Desired,
          $Applied,
          $Observed,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope)
    Confirm-NetworkStateViewModel -View $Desired
    $appliedAvailable = ($null -ne $Applied -and $Applied.Available)
    $observedAvailable = ($null -ne $Observed -and $Observed.Available)
    if ($appliedAvailable) { Confirm-NetworkStateViewModel -View $Applied }
    if ($observedAvailable) { Confirm-NetworkStateViewModel -View $Observed }

    $actions = [System.Collections.Generic.List[object]]::new()
    $drift = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    if (-not $appliedAvailable) { $warnings.Add('No applied baseline exists: this is a preview only, not an authorised deployment plan.') }
    if (-not $observedAvailable) { $warnings.Add('No observed snapshot exists: drift cannot be ruled out; live refresh required before deployment.') }

    $kinds = @(Get-NetworkResourceKinds)
    foreach ($kind in $kinds) {
        $desiredItems = Get-NetworkDocumentIndex -Document $Desired.Documents[$kind]
        $appliedItems = @{}
        $observedItems = @{}
        if ($appliedAvailable) { $appliedItems = Get-NetworkDocumentIndex -Document $Applied.Documents[$kind] }
        if ($observedAvailable) { $observedItems = Get-NetworkDocumentIndex -Document $Observed.Documents[$kind] }

        if ($observedAvailable) {
            # Objects never tracked in applied state are unmanaged and never deleted.
            foreach ($key in @($appliedItems.Keys | Sort-Object)) {
                if (-not $observedItems.ContainsKey($key)) {
                    $drift.Add([pscustomobject]@{ ResourceKind=$kind; Key=$key; Change='MissingFromObserved' })
                }
                elseif ((Get-NetworkCanonicalItem $appliedItems[$key]) -cne (Get-NetworkCanonicalItem $observedItems[$key])) {
                    $drift.Add([pscustomobject]@{ ResourceKind=$kind; Key=$key; Change='ExternallyModified' })
                }
            }
            foreach ($key in @($desiredItems.Keys | Sort-Object)) {
                if (-not $appliedItems.ContainsKey($key) -and $observedItems.ContainsKey($key)) {
                    $drift.Add([pscustomobject]@{ ResourceKind=$kind; Key=$key; Change='UnmanagedKeyCollision' })
                }
            }
        }

        foreach ($key in @($desiredItems.Keys | Sort-Object)) {
            $after = $desiredItems[$key]
            $before = if ($appliedItems.ContainsKey($key)) { $appliedItems[$key] } else { $null }
            $change = ''
            if ($null -eq $before) { $change = 'Create' }
            elseif ((Get-NetworkCanonicalItem $before) -cne (Get-NetworkCanonicalItem $after)) {
                if ($kind -eq 'edgeFirewallRules' -and
                    (Get-NetworkCanonicalItem -Item $before -IgnoreOrder) -ceq (Get-NetworkCanonicalItem -Item $after -IgnoreOrder)) {
                    $change = 'Move'
                }
                else { $change = 'Update' }
            }
            if ($change) {
                $actions.Add([pscustomobject]@{ ResourceKind=$kind; Key=$key; Change=$change; Before=$before; After=$after; DependsOn=@() })
            }
        }
        foreach ($key in @($appliedItems.Keys | Sort-Object)) {
            if (-not $desiredItems.ContainsKey($key)) {
                $actions.Add([pscustomobject]@{ ResourceKind=$kind; Key=$key; Change='Delete'; Before=$appliedItems[$key]; After=$null; DependsOn=@() })
            }
        }
    }

    $createdSets = @{}
    foreach ($action in @($actions | Where-Object { $_.ResourceKind -eq 'ipSets' -and $_.Change -eq 'Create' })) {
        $createdSets[$action.Key] = $true
    }
    foreach ($action in @($actions | Where-Object { $_.ResourceKind -eq 'edgeFirewallRules' -and $_.Change -ne 'Delete' })) {
        $deps = [System.Collections.Generic.List[string]]::new()
        foreach ($key in @($action.After.sourceIpSets) + @($action.After.destinationIpSets)) {
            if ($createdSets.ContainsKey([string]$key) -and -not $deps.Contains("ipSets/$key")) { $deps.Add("ipSets/$key") }
        }
        $action.DependsOn = @($deps.ToArray() | Sort-Object)
    }
    # Create sets before rules; delete rules before sets. All actions deterministic.
    $priorities = @{ 'ipSets/Create'=10; 'ipSets/Update'=20; 'manualIpReservations/Create'=30; 'manualIpReservations/Update'=40;
                     'edgeFirewallRules/Delete'=50; 'edgeFirewallRules/Create'=60; 'edgeFirewallRules/Update'=70;
                     'edgeFirewallRules/Move'=80; 'manualIpReservations/Delete'=90; 'ipSets/Delete'=100 }
    $sorted = @($actions.ToArray() | Sort-Object @{Expression={ $priorities[('{0}/{1}' -f $_.ResourceKind,$_.Change)] }}, @{Expression={$_.Key}})
    $counts = [ordered]@{ Create=0; Update=0; Move=0; Delete=0 }
    foreach ($action in $sorted) { $counts[$action.Change]++ }

    return [pscustomobject]@{
        schemaVersion = 1
        environment = $Environment
        scope = $Scope
        observedAvailable = [bool]$observedAvailable
        appliedAvailable = [bool]$appliedAvailable
        blocked = [bool]($drift.Count -gt 0 -or -not $observedAvailable -or -not $appliedAvailable)
        summary = [pscustomobject]$counts
        warnings = @($warnings.ToArray())
        drift = @($drift.ToArray())
        actions = $sorted
    }
}

Export-ModuleMember -Function New-NetworkChangePlan

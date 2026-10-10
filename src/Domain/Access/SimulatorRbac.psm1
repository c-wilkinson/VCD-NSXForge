# Synthetic UI and simulator policy. Not AD/VMware identity or production authorization.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\Topology\TopologyPolicy.psm1') -ErrorAction Stop

function Get-SimulatorActorRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,
          [Parameter(Mandatory)][string]$ActorDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$ActorTier,
          [Parameter(Mandatory)][string]$TargetDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$TargetTier)
    $decision = Get-SimulatorAccessDecision -Dataset $Dataset -SourceDomain $ActorDomain -SourceTier $ActorTier -TargetDomain $TargetDomain -TargetTier $TargetTier
    $role = if (-not $decision.canManage) { 'Viewer' } elseif ($ActorTier -eq 0) { 'Administrator' } else { 'Editor' }
    return [pscustomobject]@{Role=$role; Decision=$decision; Synthetic=$true}
}

function Test-SimulatorRolePermission {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Viewer','Editor','Administrator')][string]$Role,
          [Parameter(Mandatory)][ValidateSet('Read','Monitor','Edit','BulkEdit','UseTemplate','Plan','SaveDraft','Apply')][string]$Operation)
    if ($Operation -in @('Read','Monitor')) { return $true }
    if ($Role -eq 'Viewer') { return $false }
    if ($Operation -eq 'Apply') { return ($Role -eq 'Administrator') }
    return $true
}

Export-ModuleMember -Function Get-SimulatorActorRole, Test-SimulatorRolePermission

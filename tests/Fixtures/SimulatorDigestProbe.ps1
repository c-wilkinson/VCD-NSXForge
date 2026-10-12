# Independent PowerShell 5.1 process probe for the simulator approval digest.
# Intentionally outputs only a fingerprint; never starts a server or writes state.
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\Simulator\SimulatorClient.psm1') -ErrorAction Stop

# The probe runs in a fresh powershell.exe process, independent of the parent test runner.
# Resolve every command it uses before comparing approval fingerprints.
foreach ($name in @('Import-SimulatorTopology','Get-SimulatorWorkspaceState','Copy-NetworkDocuments','Set-NetworkDraftItem','Get-SimulatorDraftPlan')) {
    $null=Get-Command -Name $name -CommandType Function -ErrorAction Stop
}

$topology=Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json'
$data=Import-SimulatorTopology -Path $topology
$gateway=@($data.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
$baseline=Get-SimulatorWorkspaceState -Dataset $data -GatewayId ([string]$gateway.gatewayId)
$docs=Copy-NetworkDocuments -Documents $baseline.documents
$nextOrder=([int](($docs.edgeFirewallRules.items | Measure-Object -Property order -Maximum).Maximum))+1
$rule=[pscustomobject]@{
    key='manual-test';name='Manual Test';description='';order=$nextOrder
    action='ALLOW';enabled=$true;logging=$true
    sourceIpSets=@();destinationIpSets=@()
    services=@([pscustomobject]@{protocol='TCP';ports=@('443','1433')})
}
$docs=Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $rule -Create
$approved=Get-SimulatorDraftPlan -Baseline $baseline -DesiredDocuments $docs
if ($approved.plan.blocked -or $approved.plan.summary.Create -ne 1) { throw 'Unexpected enterprise plan in digest probe.' }
[Console]::Out.WriteLine([string]$approved.planDigest)

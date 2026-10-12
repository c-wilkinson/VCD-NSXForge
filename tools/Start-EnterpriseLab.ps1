#requires -Version 5.1
<#
.SYNOPSIS
    Starts the separate, fictional six-scope enterprise scenario for VCD-NSXForge.
.DESCRIPTION
    Does not modify simulator/topology.json or simulator/runtime-state.json.
    To discard previous enterprise-lab changes, use -ResetState; a dated backup
    is created first. No workplace credentials or VMware services are involved.
#>
[CmdletBinding()]
param(
    [ValidateRange(1024,65535)][int]$Port = 8765,
    [switch]$ResetState,
    [switch]$NoTraffic,
    [ValidateRange(1,60)][int]$TrafficIntervalSeconds = 2
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scenario = Join-Path $root 'simulator\scenarios\enterprise-lab\topology.json'
$runtime = Join-Path $root 'simulator\runtime-state.json.enterprise-lab'
$trafficCases = Join-Path $root 'simulator\scenarios\enterprise-lab\flow-cases.json'
if (-not [IO.File]::Exists($scenario)) { throw "Enterprise scenario was not found at $scenario" }
if ($ResetState -and [IO.File]::Exists($runtime)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $backup = "$runtime.$stamp.$([guid]::NewGuid().ToString('n')).bak"
    [IO.File]::Copy($runtime, $backup, $false)
    [IO.File]::Delete($runtime)
    Write-Host "Saved previous enterprise-lab state to: $backup" -ForegroundColor Yellow
}
Import-Module (Join-Path $root 'src\Infrastructure\Simulator\SimulatorServer.psm1') -ErrorAction Stop
Write-Host 'Enterprise lab: synthetic DomainA/B/C, Tier 0/1, SQL FCI, RDS, MCM, SCM, ADO' -ForegroundColor Cyan
Write-Host "Scenario: $scenario" -ForegroundColor DarkCyan
Write-Host "Persistent edits: $runtime" -ForegroundColor DarkCyan
$trafficMode = if ($NoTraffic) { 'disabled' } else { "enabled every $TrafficIntervalSeconds seconds" }
Write-Host "Synthetic background traffic: $trafficMode (32 curated flows; all six gateways)" -ForegroundColor Cyan
if ($NoTraffic) {
    Start-VcdSimulatorServer -TopologyPath $scenario -Port $Port -PersistencePath $runtime
} else {
    Start-VcdSimulatorServer -TopologyPath $scenario -Port $Port -PersistencePath $runtime -TrafficCasesPath $trafficCases -TrafficIntervalSeconds $TrafficIntervalSeconds
}

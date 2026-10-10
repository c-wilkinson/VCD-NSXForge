#requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port=8765, [switch]$ResetState)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'src\Infrastructure\Simulator\SimulatorServer.psm1') -Force
$runtime = Join-Path $root 'simulator\runtime-state.json'
if ($ResetState -and [IO.File]::Exists($runtime)) { [IO.File]::Delete($runtime) }
Start-VcdSimulatorServer -TopologyPath (Join-Path $root 'simulator\topology.json') -Port $Port -PersistencePath $runtime

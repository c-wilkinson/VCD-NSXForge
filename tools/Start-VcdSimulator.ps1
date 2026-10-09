#requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port=8765)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'src\Infrastructure\Simulator\SimulatorServer.psm1') -Force
Start-VcdSimulatorServer -TopologyPath (Join-Path $root 'simulator\topology.json') -Port $Port

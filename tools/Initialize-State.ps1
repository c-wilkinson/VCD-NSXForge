#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Environment,
      [Parameter(Mandatory)][string]$Scope,
      [string]$StateRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $StateRoot) { $StateRoot = Join-Path $root 'state' }
Import-Module (Join-Path $root 'src\Infrastructure\State\StateRepository.psm1') -Force
$directory = Initialize-NetworkDesiredState -StateRoot $StateRoot -Environment $Environment -Scope $Scope
Write-Host "New desired-state documents: $directory"
Write-Host 'No applied/observed state was created; planning will correctly report an unverified baseline.'

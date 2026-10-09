#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Environment = 'demo',
    [string]$Scope = 'edge-gw-demo',
    [string]$StateRoot = '',
    [string]$OutputDirectory = '',
    [switch]$FailOnBlocked
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $StateRoot) {
    if ($Environment -eq 'demo') { $StateRoot = Join-Path $projectRoot 'examples\demo-state' }
    else { $StateRoot = Join-Path $projectRoot 'state' }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'reports' }
Import-Module (Join-Path $projectRoot 'src\Application\Planning\OfflinePlan.psm1') -Force
try {
    $plan = Get-OfflineNetworkPlan -StateRoot $StateRoot -Environment $Environment -Scope $Scope
    $paths = Export-OfflineNetworkPlan -Plan $plan -OutputDirectory $OutputDirectory
    Write-Host $paths.Summary
    Write-Host "Blocked: $($paths.Blocked) | Drift events: $(@($plan.drift).Count)"
    Write-Host "JSON: $($paths.Json)"
    Write-Host "HTML: $($paths.Html)"
    if ($FailOnBlocked -and $plan.blocked) { exit 2 }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}

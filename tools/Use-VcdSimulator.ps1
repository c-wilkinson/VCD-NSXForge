#requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port=8765, [switch]$Restore)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $root 'config\application.json'
$backup = Join-Path $root 'config\application.json.before-simulator'
if ($Restore) {
    if (-not [IO.File]::Exists($backup)) { throw 'No configuration backup exists to restore.' }
    [IO.File]::Copy($backup,$configPath,$true)
    [IO.File]::Delete($backup)
    Write-Host 'Restored original VCD configuration.'
    return
}
# Fail instead of replacing a prior saved work configuration.
if ([IO.File]::Exists($backup)) { throw 'Simulator backup already exists. Run -Restore before configuring again.' }
$dataset = Get-Content -LiteralPath (Join-Path $root 'simulator\topology.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target = @($dataset.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]
$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
[IO.File]::Copy($configPath,$backup,$false)
try {
    if ($cfg.vcd.PSObject.Properties.Name -contains 'mode') { $cfg.vcd.mode='Simulator' }
    else { $cfg.vcd | Add-Member -NotePropertyName mode -NotePropertyValue 'Simulator' }
    $cfg.vcd.apiUrl = "http://127.0.0.1:$Port"
    $cfg.vcd.gatewayId = [string]$target.gatewayId
    $cfg.vcd.networkIds = @([string]$target.networkId)
    $cfg.vcd.tenantContextOrgId = ''
    $cfg.vcd.authentication = 'BearerToken'
    $cfg | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-Host ("Simulator configured. Demo target: DomainB Tier 1; port {0}." -f $Port)
    Write-Host 'Restore your previous settings with .\tools\Use-VcdSimulator.ps1 -Restore'
}
catch {
    [IO.File]::Copy($backup,$configPath,$true)
    [IO.File]::Delete($backup)
    throw
}

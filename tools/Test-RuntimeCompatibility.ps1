#requires -Version 5.1

[CmdletBinding()]
param([string]$OutputPath = '', [switch]$IncludeUi)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$mode = [string]$ExecutionContext.SessionState.LanguageMode
if ($mode -ne 'FullLanguage') {
    Write-Warning "Host compatibility BLOCKED: PowerShell language mode is '$mode'. VCD-NSXForge requires approved FullLanguage for WinForms and runspaces. No application-control bypass is attempted."
    exit 2
}
$projectRoot = Join-Path $PSScriptRoot '..'
try {
    Import-Module (Join-Path $projectRoot 'src\Runtime\RuntimeCompatibility.psm1') -ErrorAction Stop
    $report = Get-RuntimeCompatibilityReport -ApplicationRoot $projectRoot -ProbeCapabilities -ProbeWinForms:$IncludeUi
    Write-Host ('Startup readiness: {0}' -f $(if ($report.StartupReady) { 'PASS (host-policy evidence still required)' } else { 'BLOCKED' }))
    Write-Host ('PowerShell: {0}; Language: {1}; STA: {2}; Effective execution policy: {3}' -f $report.PowerShellVersion, $report.LanguageMode, $report.ApartmentState, $report.ExecutionPolicy)
    Write-Host ('Probes: module={0}; worker={1}; WinForms={2}' -f $report.Capabilities.ModuleImport, $report.Capabilities.WorkerRunspace, $report.Capabilities.WinFormsConstruction)
    Write-Host 'AppLocker, WDAC and signing trust remain unverified until security-approved host evidence is recorded.'
    foreach ($finding in $report.Findings) { Write-Warning $finding }
    if ($OutputPath) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $full -Encoding UTF8 -ErrorAction Stop
        Write-Host "Report written: $full"
    }
    if (-not $report.StartupReady) { exit 2 }
}
catch {
    # Do not print an arbitrary policy exception body that might contain secrets.
    Write-Warning 'Host compatibility check could not complete. Confirm the diagnostic script/module is permitted by your approved policy and review policy events with security.'
    exit 3
}

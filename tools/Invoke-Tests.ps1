#requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('JunitPath')][string]$NUnitPath = '',
    [switch]$IncludeUi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RunUiTests = [bool]$IncludeUi
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjectRoot 'tests\TestHarness.ps1')

if (-not $NUnitPath) {
    $NUnitPath = Join-Path $ProjectRoot 'test-results\TEST-VcdNetworkManager.xml'
}

$files = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'tests') -Recurse -Filter '*.Tests.ps1' -File | Sort-Object FullName)
foreach ($file in $files) {
    $script:CurrentTestFile = $file.Name
    Write-Host ("`n-- $($file.Name) --") -ForegroundColor Cyan
    . $file.FullName
}
$results = @($script:TestResults.ToArray())
$failed = @($results | Where-Object { -not $_.Passed })
$skipped = @($results | Where-Object { $_.Skipped })
Write-Host ("`nTotal: {0}; Passed: {1}; Failed: {2}; Skipped: {3}" -f $results.Count, ($results.Count - $failed.Count - $skipped.Count), $failed.Count, $skipped.Count)
Save-NUnitReport -Path $NUnitPath
Write-Host "NUnit 3 report saved: $NUnitPath"
if ($failed.Count -gt 0) { exit 1 }
exit 0

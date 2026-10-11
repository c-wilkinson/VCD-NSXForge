#requires -Version 5.1
[CmdletBinding()]
param([string]$NUnitPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjectRoot 'tests\TestHarness.ps1')

if (-not $NUnitPath) {
    $NUnitPath = Join-Path $ProjectRoot 'test-results\TEST-Vcd106-Contracts.xml'
}
$script:CurrentTestFile = 'Vcd106ApiContract.Tests.ps1'
$file = Join-Path $ProjectRoot 'tests\Contract\Vcd106ApiContract.Tests.ps1'
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    $details = (@($parseErrors) | ForEach-Object { 'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
    Invoke-TestCase -Name 'VCD 10.6 contract test file parses' -Body { throw $details }
}
else { . $file }
$results = @($script:TestResults.ToArray())
$failed = @($results | Where-Object { -not $_.Passed })
$skipped = @($results | Where-Object { $_.Skipped })
Write-Host ("Total: {0}; Passed: {1}; Failed: {2}; Skipped: {3}" -f $results.Count, ($results.Count - $failed.Count - $skipped.Count), $failed.Count, $skipped.Count)
Save-NUnitReport -Path $NUnitPath
Write-Host "NUnit 3 report saved: $NUnitPath"
if ($failed.Count -gt 0) { exit 1 }
exit 0

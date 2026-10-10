#requires -Version 5.1
<#
.SYNOPSIS
    Summarizes VCD-NSXForge's NUnit 3 report in a GitHub Actions job summary.
.DESCRIPTION
    No third-party PowerShell modules or NUnit executable are required.
    A missing, malformed or empty report fails the step rather than showing a
    misleading green check. Individual NUnit failure messages are annotated.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NUnitPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JobSummary {
    param([string[]]$Lines)

    $text = ($Lines -join "`n") + "`n"
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Write-Host $text
        return
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $text, $encoding)
}

function ConvertTo-GitHubCommandText {
    param([string]$Text)
    # Escape workflow command delimiters, then prevent multi-line injection.
    return $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

$report = [System.IO.Path]::GetFullPath($NUnitPath)
if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
    Write-JobSummary @(
        '## VCD-NSXForge NUnit 3 results',
        '',
        '**No NUnit report was generated.** Review the test-runner log.'
    )
    Write-Error "NUnit report is missing: $report"
    exit 1
}

try {
    $document = New-Object System.Xml.XmlDocument
    $document.Load($report)
    $root = $document.DocumentElement
    if ($null -eq $root -or $root.LocalName -ne 'test-run') {
        throw 'Expected an NUnit 3 <test-run> XML document.'
    }

    $total   = [int]$root.GetAttribute('total')
    $passed  = [int]$root.GetAttribute('passed')
    $failed  = [int]$root.GetAttribute('failed')
    $skipped = [int]$root.GetAttribute('skipped')
    if ($total -le 0 -or ($passed + $failed + $skipped) -ne $total) {
        throw "Invalid NUnit test counts: total=$total passed=$passed failed=$failed skipped=$skipped"
    }

    $lines = @(
        '## VCD-NSXForge NUnit 3 results',
        '',
        '| Total | Passed | Failed | Skipped |',
        '| ---: | ---: | ---: | ---: |',
        "| $total | $passed | $failed | $skipped |",
        '',
        'The original NUnit 3 XML is available as a workflow artifact.'
    )

    $failedCases = @($document.SelectNodes('//test-case[@result="Failed"]'))
    if ($failedCases.Count -gt 0) {
        $lines += @('', '### Failed tests')
        foreach ($test in $failedCases) {
            $testName = [string]$test.GetAttribute('fullname')
            $failure = $test.SelectSingleNode('failure/message')
            $message = if ($null -ne $failure) { [string]$failure.InnerText } else { 'No failure message supplied' }
            $oneLine = (($message -replace '[\r\n]+', ' ') -replace '\|', '\|')
            $oneLine = $oneLine.Substring(0, [Math]::Min(250, $oneLine.Length))
            $safeName = ($testName -replace '[\r\n]+', ' ') -replace '\|', '\|'
            $lines += "- **$safeName**: $oneLine"
            $annotation = ConvertTo-GitHubCommandText -Text ("$testName : $message")
            Write-Host "::error title=NUnit test failed::$annotation"
        }
    }

    Write-JobSummary -Lines $lines
    Write-Host "NUnit: total=$total passed=$passed failed=$failed skipped=$skipped"

    if ($failed -gt 0) { exit 1 }
}
catch {
    Write-JobSummary @(
        '## VCD-NSXForge NUnit 3 results',
        '',
        "**Invalid NUnit report:** $($_.Exception.Message)"
    )
    Write-Error "Could not read NUnit 3 report: $($_.Exception.Message)"
    exit 1
}

# Native Windows PowerShell 5.1 test harness, with NUnit 3 XML reporting.
Set-StrictMode -Version Latest
$script:TestResults = [System.Collections.Generic.List[object]]::new()
$script:TestRunStartedUtc = [datetime]::UtcNow
$script:CurrentTestFile = 'Unknown.Tests.ps1'

function Invoke-TestCase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    $started = [datetime]::UtcNow
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $timer.Stop()
        $script:TestResults.Add([pscustomobject]@{
            Name = $Name; Suite = $script:CurrentTestFile; Passed = $true; Skipped = $false
            Message = ''; StackTrace = ''; Milliseconds = $timer.ElapsedMilliseconds
            StartedUtc = $started; EndedUtc = [datetime]::UtcNow
        })
        Write-Host ("PASS {0} ({1} ms)" -f $Name, $timer.ElapsedMilliseconds) -ForegroundColor Green
    }
    catch {
        $timer.Stop()
        $script:TestResults.Add([pscustomobject]@{
            Name = $Name; Suite = $script:CurrentTestFile; Passed = $false; Skipped = $false
            Message = $_.Exception.ToString(); StackTrace = [string]$_.ScriptStackTrace
            Milliseconds = $timer.ElapsedMilliseconds
            StartedUtc = $started; EndedUtc = [datetime]::UtcNow
        })
        Write-Host ("FAIL {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Skip-TestCase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Because)
    $now = [datetime]::UtcNow
    $script:TestResults.Add([pscustomobject]@{
        Name = $Name; Suite = $script:CurrentTestFile; Passed = $true; Skipped = $true
        Message = $Because; StackTrace = ''; Milliseconds = 0
        StartedUtc = $now; EndedUtc = $now
    })
    Write-Host ("SKIP {0}: {1}" -f $Name, $Because) -ForegroundColor Yellow
}

function Assert-True {
    param([bool]$Condition, [string]$Because = 'Expected condition to be true')
    if (-not $Condition) { throw $Because }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = 'Values are different')
    if (-not [object]::Equals($Expected, $Actual)) { throw "$Because. Expected '$Expected' but found '$Actual'." }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Because = 'Expected an exception')
    $thrown = $false
    try { & $Body | Out-Null } catch { $thrown = $true }
    if (-not $thrown) { throw $Because }
}

function Save-NUnitReport {
    <#
      Emits NUnit 3 XML directly consumable by Azure DevOps PublishTestResults@2
      and GitHub Actions test reporters with an NUnit 3 parser.
      $Results is injectable so the XML writer can test failures and skips without
      introducing a genuine failing test into the current test run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Results
    )
    if (-not $PSBoundParameters.ContainsKey('Results')) {
        $Results = @($script:TestResults.ToArray())
    }

    $total = @($Results).Count
    $failed = @($Results | Where-Object { -not $_.Passed }).Count
    $skipped = @($Results | Where-Object { $_.Skipped }).Count
    $passed = $total - $failed - $skipped
    $outcome = if ($failed -gt 0) { 'Failed' } elseif ($passed -gt 0) { 'Passed' } else { 'Skipped' }
    $now = [datetime]::UtcNow
    $start = $script:TestRunStartedUtc
    $duration = [math]::Max(0, ($now - $start).TotalSeconds)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $elapsedText = $duration.ToString('0.000', $invariant)
    $stampFormat = 'yyyy-MM-ddTHH:mm:ss.fffZ'

    $xml = [System.Xml.XmlDocument]::new()
    $declaration = $xml.CreateXmlDeclaration('1.0', 'utf-8', $null)
    [void]$xml.AppendChild($declaration)
    $run = $xml.CreateElement('test-run')
    [void]$xml.AppendChild($run)
    $run.SetAttribute('id', '0')
    $run.SetAttribute('name', 'VcdNetworkManager')
    $run.SetAttribute('fullname', 'VcdNetworkManager')
    $run.SetAttribute('testcasecount', [string]$total)
    $run.SetAttribute('result', $outcome)
    $run.SetAttribute('total', [string]$total)
    $run.SetAttribute('passed', [string]$passed)
    $run.SetAttribute('failed', [string]$failed)
    $run.SetAttribute('inconclusive', '0')
    $run.SetAttribute('skipped', [string]$skipped)
    $run.SetAttribute('asserts', '0')
    $run.SetAttribute('start-time', $start.ToString($stampFormat, $invariant))
    $run.SetAttribute('end-time', $now.ToString($stampFormat, $invariant))
    $run.SetAttribute('duration', $elapsedText)

    $suite = $xml.CreateElement('test-suite')
    [void]$run.AppendChild($suite)
    $suite.SetAttribute('type', 'Assembly')
    $suite.SetAttribute('id', '0-1')
    $suite.SetAttribute('name', 'VcdNetworkManager.Tests')
    $suite.SetAttribute('fullname', 'VcdNetworkManager.Tests')
    $suite.SetAttribute('runstate', 'Runnable')
    $suite.SetAttribute('testcasecount', [string]$total)
    $suite.SetAttribute('result', $outcome)
    $suite.SetAttribute('total', [string]$total)
    $suite.SetAttribute('passed', [string]$passed)
    $suite.SetAttribute('failed', [string]$failed)
    $suite.SetAttribute('inconclusive', '0')
    $suite.SetAttribute('skipped', [string]$skipped)
    $suite.SetAttribute('asserts', '0')
    $suite.SetAttribute('start-time', $start.ToString($stampFormat, $invariant))
    $suite.SetAttribute('end-time', $now.ToString($stampFormat, $invariant))
    $suite.SetAttribute('duration', $elapsedText)

    $counter = 2
    foreach ($result in $Results) {
        $case = $xml.CreateElement('test-case')
        [void]$suite.AppendChild($case)
        $case.SetAttribute('id', "0-$counter")
        $counter++
        $case.SetAttribute('name', [string]$result.Name)
        $case.SetAttribute('fullname', ('VcdNetworkManager.Tests.{0}.{1}' -f $result.Suite, $result.Name))
        $case.SetAttribute('classname', ('VcdNetworkManager.Tests.{0}' -f $result.Suite))
        $case.SetAttribute('methodname', [string]$result.Name)
        $case.SetAttribute('runstate', $(if ($result.Skipped) { 'Ignored' } else { 'Runnable' }))
        $case.SetAttribute('result', $(if ($result.Skipped) { 'Skipped' } elseif ($result.Passed) { 'Passed' } else { 'Failed' }))
        if ($result.Skipped) { $case.SetAttribute('label', 'Ignored') }
        $case.SetAttribute('duration', ([math]::Max(0, $result.Milliseconds / 1000.0)).ToString('0.000', $invariant))
        $case.SetAttribute('asserts', '0')
        $case.SetAttribute('start-time', $result.StartedUtc.ToString($stampFormat, $invariant))
        $case.SetAttribute('end-time', $result.EndedUtc.ToString($stampFormat, $invariant))

        if ($result.Skipped) {
            $reason = $xml.CreateElement('reason')
            $message = $xml.CreateElement('message')
            $message.InnerText = [string]$result.Message
            [void]$reason.AppendChild($message)
            [void]$case.AppendChild($reason)
        }
        elseif (-not $result.Passed) {
            $failure = $xml.CreateElement('failure')
            $message = $xml.CreateElement('message')
            $message.InnerText = [string]$result.Message
            [void]$failure.AppendChild($message)
            $trace = $xml.CreateElement('stack-trace')
            $trace.InnerText = [string]$result.StackTrace
            [void]$failure.AppendChild($trace)
            [void]$case.AppendChild($failure)
        }
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.Xml.XmlWriter]::Create($fullPath, $settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
}

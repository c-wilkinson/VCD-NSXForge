Invoke-TestCase -Name 'Native assertions detect mismatch and missing exceptions' -Body {
    Assert-Throws { Assert-Equal 'first' 'second' }
    Assert-Throws { Assert-True $false }
    Assert-Throws { Assert-Throws { $null = 1 } }
    Assert-Equal 4 (2 + 2)
}

Invoke-TestCase -Name 'NUnit 3 report writer emits assembly suite and test cases' -Body {
    $file = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n') + '.xml')
    try {
        Save-NUnitReport -Path $file
        [xml]$doc = [IO.File]::ReadAllText($file)
        Assert-Equal 'test-run' $doc.DocumentElement.LocalName
        Assert-Equal 'Assembly' $doc.SelectSingleNode('/test-run/test-suite').GetAttribute('type')
        Assert-True (@($doc.SelectNodes('/test-run/test-suite/test-case')).Count -ge 1)
        Assert-True ($doc.DocumentElement.GetAttribute('total') -ne '')
    }
    finally { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
}

Invoke-TestCase -Name 'NUnit 3 report serializes pass fail skip and escaped failure data' -Body {
    $file = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n') + '.xml')
    $now = [datetime]::UtcNow
    $cases = @(
        [pscustomobject]@{ Name='All good'; Suite='Mock.Tests.ps1'; Passed=$true; Skipped=$false; Message=''; StackTrace=''; Milliseconds=250; StartedUtc=$now; EndedUtc=$now }
        [pscustomobject]@{ Name='Broken'; Suite='Mock.Tests.ps1'; Passed=$false; Skipped=$false; Message='Expected <pass> & got "fail"'; StackTrace='at Mock.Tests.ps1:line 42'; Milliseconds=125; StartedUtc=$now; EndedUtc=$now }
        [pscustomobject]@{ Name='Not run'; Suite='Mock.Tests.ps1'; Passed=$true; Skipped=$true; Message='No desktop session'; StackTrace=''; Milliseconds=0; StartedUtc=$now; EndedUtc=$now }
    )
    try {
        Save-NUnitReport -Path $file -Results $cases
        [xml]$doc = [IO.File]::ReadAllText($file)
        Assert-Equal '3' $doc.DocumentElement.GetAttribute('total')
        Assert-Equal '1' $doc.DocumentElement.GetAttribute('passed')
        Assert-Equal '1' $doc.DocumentElement.GetAttribute('failed')
        Assert-Equal '1' $doc.DocumentElement.GetAttribute('skipped')
        Assert-Equal 'Failed' $doc.DocumentElement.GetAttribute('result')
        Assert-Equal 'Expected <pass> & got "fail"' $doc.SelectSingleNode('//test-case[@result="Failed"]/failure/message').InnerText
        Assert-True ($doc.SelectSingleNode('//test-case[@result="Failed"]/failure/stack-trace').InnerText -match 'line 42')
        Assert-Equal 'No desktop session' $doc.SelectSingleNode('//test-case[@result="Skipped"]/reason/message').InnerText
        Assert-Equal 'Passed' $doc.SelectSingleNode('//test-case[@result="Passed"]').GetAttribute('result')
    }
    finally { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
}

Invoke-TestCase -Name 'Expected-error assertions never accept missing commands as valid failures' -Body {
    $message = ''
    try { Assert-Throws { Invoke-ThisCommandDoesNotExistIssue2 } }
    catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'unavailable command') 'A missing function must fail the assertion rather than pass it'
}

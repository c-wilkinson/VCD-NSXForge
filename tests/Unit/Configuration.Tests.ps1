Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force

Invoke-TestCase -Name 'Configuration reads locked VCD 10.6 NSX-T baseline' -Body {
    $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
    Assert-Equal '10.6' $cfg.target.vcdVersion
    Assert-Equal 'NSX-T' $cfg.target.networkBacking
    Assert-Equal 5000000 ([int]$cfg.logging.maximumFileBytes)
    Assert-Equal 30 ([int]$cfg.logging.retentionDays)
}

Invoke-TestCase -Name 'Configuration rejects retention over 30 days' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'config'))
        $raw = Get-Content (Join-Path $ProjectRoot 'config\application.json') -Raw | ConvertFrom-Json
        $raw.logging.retentionDays = 31
        $raw | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $scratch 'config\application.json') -Encoding UTF8
        Assert-Throws { Read-AppConfiguration -ApplicationRoot $scratch } 'Retention over 30 days must fail'
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Configuration blocks path traversal in log path' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'config'))
        $raw = Get-Content (Join-Path $ProjectRoot 'config\application.json') -Raw | ConvertFrom-Json
        $raw.logging.directory = '..\escape'
        $raw | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $scratch 'config\application.json') -Encoding UTF8
        Assert-Throws { Read-AppConfiguration -ApplicationRoot $scratch } 'Traversal should not be allowed'
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

function Test-InvalidConfiguration {
    param([scriptblock]$Modify)
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'config'))
        $cfg = Get-Content (Join-Path $ProjectRoot 'config\application.json') -Raw | ConvertFrom-Json
        & $Modify $cfg
        $cfg | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $scratch 'config\application.json') -Encoding UTF8
        Assert-Throws { Read-AppConfiguration -ApplicationRoot $scratch }
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}
Invoke-TestCase -Name 'Config rejects invalid schema, platform or runtime constraints' -Body {
    Test-InvalidConfiguration { param($c) $c.schemaVersion = 2 }
    Test-InvalidConfiguration { param($c) $c.target.vcdVersion = '10.5' }
    Test-InvalidConfiguration { param($c) $c.target.networkBacking = 'NSX-V' }
    Test-InvalidConfiguration { param($c) $c.target.powershellVersion = '7.0' }
    Test-InvalidConfiguration { param($c) $c.runtime.maximumWorkers = 0 }
    Test-InvalidConfiguration { param($c) $c.runtime.maximumWorkers = 9 }
    Test-InvalidConfiguration { param($c) $c.runtime.uiPollMilliseconds = 49 }
    Test-InvalidConfiguration { param($c) $c.runtime.uiPollMilliseconds = 1001 }
}
Invoke-TestCase -Name 'Config rejects invalid logging settings' -Body {
    Test-InvalidConfiguration { param($c) $c.logging.maximumFileBytes = 1023 }
    Test-InvalidConfiguration { param($c) $c.logging.maximumFileBytes = 5000001 }
    Test-InvalidConfiguration { param($c) $c.logging.retentionDays = 0 }
    Test-InvalidConfiguration { param($c) $c.logging.level = 'VERBOSE' }
    Test-InvalidConfiguration { param($c) $c.logging.directory = '../outside' }
}
Invoke-TestCase -Name 'Config missing file fails explicitly' -Body {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    Assert-Throws { Read-AppConfiguration -ApplicationRoot $missing }
}

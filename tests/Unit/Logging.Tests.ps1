. (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.File.ps1')

Invoke-TestCase -Name 'Log writer rolls files before exceeding maximum bytes' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $session = New-LogFileSession -Directory $scratch -MaximumBytes 600
        try {
            for ($i = 1; $i -le 25; $i++) {
                Write-LogFileRecord -Session $session -Record ([ordered]@{ level = 'INFO'; number = $i; message = ('A' * 115) })
            }
        }
        finally { Close-LogFileSession -Session $session }
        $files = @(Get-ChildItem -LiteralPath $scratch -Filter 'network-manager*.log' -File)
        Assert-True ($files.Count -gt 1) 'Expected multiple rotated log files'
        foreach ($file in $files) { Assert-True ($file.Length -le 600) "Oversized file: $($file.Name)" }
        $records = @($files | ForEach-Object { Get-Content -LiteralPath $_.FullName } | Where-Object { $_ })
        Assert-Equal 25 $records.Count 'Each log record must be preserved'
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Oversized record becomes small placeholder' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $session = New-LogFileSession -Directory $scratch -MaximumBytes 512
        try { Write-LogFileRecord -Session $session -Record ([ordered]@{ payload = ('X' * 3000) }) }
        finally { Close-LogFileSession -Session $session }
        $contents = Get-Content -LiteralPath (Join-Path $scratch 'network-manager.log') -Raw
        Assert-True ($contents -match 'Oversized record omitted')
        Assert-True (([IO.FileInfo](Join-Path $scratch 'network-manager.log')).Length -le 512)
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Expired rotated logs are removed but current logs retained' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory($scratch)
        $old = Join-Path $scratch 'network-manager.20250101T000000000Z.00000.log'
        $recent = Join-Path $scratch 'network-manager.20260201T000000000Z.00000.log'
        $active = Join-Path $scratch 'network-manager.log'
        [IO.File]::WriteAllText($old, 'old')
        [IO.File]::WriteAllText($recent, 'recent')
        [IO.File]::WriteAllText($active, 'active')
        $now = [DateTime]::UtcNow
        [IO.File]::SetLastWriteTimeUtc($old, $now.AddDays(-31))
        [IO.File]::SetLastWriteTimeUtc($recent, $now.AddDays(-29))
        [IO.File]::SetLastWriteTimeUtc($active, $now.AddDays(-31))
        Remove-ExpiredLogFiles -Directory $scratch -RetentionDays 30 -UtcNow $now
        Assert-True (-not [IO.File]::Exists($old)) 'Old rotated file should be deleted'
        Assert-True ([IO.File]::Exists($recent)) 'Recent rotated file should survive'
        Assert-True ([IO.File]::Exists($active)) 'Active file must not be removed'
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Stale active log is rotated on startup' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory($scratch)
        $active = Join-Path $scratch 'network-manager.log'
        [IO.File]::WriteAllText($active, 'yesterday')
        [IO.File]::SetLastWriteTimeUtc($active, [DateTime]::UtcNow.AddDays(-1))
        $session = New-LogFileSession -Directory $scratch -MaximumBytes 5000000
        Close-LogFileSession -Session $session
        $archived = @(Get-ChildItem -LiteralPath $scratch -Filter 'network-manager.*.log' -File)
        Assert-Equal 1 $archived.Count
        Assert-True (([IO.File]::ReadAllText($archived[0].FullName)) -eq 'yesterday')
        Assert-True ([IO.File]::Exists($active)) 'A new active log should exist'
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Log writer enforces exact byte ceiling and preserves UTF8 records' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $session = New-LogFileSession -Directory $scratch -MaximumBytes 512
        try {
            for ($i=0; $i -lt 12; $i++) {
                Write-LogFileRecord -Session $session -Record ([ordered]@{ id=$i; message=('é' * 40) })
            }
        }
        finally { Close-LogFileSession -Session $session }
        $files = @(Get-ChildItem -LiteralPath $scratch -Filter 'network-manager*.log' -File)
        Assert-True ($files.Count -gt 1)
        foreach ($file in $files) { Assert-True ($file.Length -le 512) 'Exceeds byte limit' }
        $records = @($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Encoding UTF8 } | Where-Object { $_ })
        Assert-Equal 12 $records.Count
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Daily rollover rotates an active log and leaves a fresh file' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    try {
        $session = New-LogFileSession -Directory $scratch -MaximumBytes 2048
        try {
            Write-LogFileRecord -Session $session -Record ([ordered]@{ message='before' })
            $session.ActiveUtcDate = [DateTime]::UtcNow.Date.AddDays(-1)
            Invoke-DailyLogRollover -Session $session
            Write-LogFileRecord -Session $session -Record ([ordered]@{ message='after' })
        }
        finally { Close-LogFileSession -Session $session }
        $archived = @(Get-ChildItem -LiteralPath $scratch -Filter 'network-manager.*.log' -File)
        Assert-Equal 1 $archived.Count
        Assert-True ([IO.File]::ReadAllText($archived[0].FullName).Contains('before'))
        Assert-True ([IO.File]::ReadAllText((Join-Path $scratch 'network-manager.log')).Contains('after'))
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'Log retention is safe on a missing directory' -Body {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    Remove-ExpiredLogFiles -Directory $missing -RetentionDays 30
    Assert-True (-not [IO.Directory]::Exists($missing))
}

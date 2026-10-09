Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force

Invoke-TestCase -Name 'Real log writer flushes events and respects minimum severity' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30 -MinimumLevel WARN
        Write-AppLog -Logger $logger -Component 'Test' -Message 'must be filtered' -Level INFO
        Write-AppLog -Logger $logger -Component 'Test' -Message 'must survive' -Level WARN -OperationId 'op-123'
        Write-AppLog -Logger $logger -Component 'Test' -Message 'also survives' -Level ERROR
        Stop-AppLogger -Logger $logger
        $logger = $null
        $lines = @(Get-Content -LiteralPath (Join-Path $scratch 'network-manager.log'))
        Assert-Equal 2 $lines.Count
        $parsed = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal 'op-123' $parsed[0].operationId
        Assert-Equal 'ERROR' $parsed[1].level
        Assert-True (-not ([IO.File]::ReadAllText((Join-Path $scratch 'network-manager.log')).Contains('must be filtered')))
    }
    finally {
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Invoke-TestCase -Name 'Real log writer handles simultaneous producers without losing records' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        $pool = [runspacefactory]::CreateRunspacePool(1,4)
        $pool.Open()
        $producers = [System.Collections.Generic.List[object]]::new()
        try {
            for ($i=0; $i -lt 4; $i++) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                $null = $ps.AddScript({
                    param($queue,$signal)
                    for ($j=0; $j -lt 50; $j++) {
                        $queue.Enqueue([ordered]@{timestamp='2026-10-09T00:00:00Z';level='INFO';component='Test';operationId='parallel';message='event';properties=@{} })
                        $signal.Set()
                    }
                }.ToString()).AddArgument($logger.Queue).AddArgument($logger.Signal)
                $producers.Add([pscustomobject]@{ Pipeline=$ps; Handle=$ps.BeginInvoke() })
            }
            foreach ($producer in $producers) { $null = $producer.Pipeline.EndInvoke($producer.Handle) }
        }
        finally {
            foreach ($producer in $producers) { $producer.Pipeline.Dispose() }
            $pool.Dispose()
        }
        Stop-AppLogger -Logger $logger
        $logger = $null
        $lines = @(Get-Content -LiteralPath (Join-Path $scratch 'network-manager.log'))
        Assert-Equal 200 $lines.Count
    }
    finally {
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Invoke-TestCase -Name 'Log writer rotates numerous records under strict 5MB cap' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        for ($i=0; $i -lt 16; $i++) {
            Write-AppLog -Logger $logger -Component 'Test' -Message ('x' * 450000) -OperationId ([string]$i)
        }
        Stop-AppLogger -Logger $logger
        $logger = $null
        $files = @(Get-ChildItem -LiteralPath $scratch -Filter 'network-manager*.log' -File)
        Assert-True ($files.Count -ge 2)
        foreach ($file in $files) { Assert-True ($file.Length -le 5000000) "Oversized file: $($file.Name)" }
        Assert-Equal 16 (@($files | ForEach-Object { @(Get-Content -LiteralPath $_.FullName) } | Where-Object { $_ }).Count)
    }
    finally {
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

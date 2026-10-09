Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force

Invoke-TestCase -Name 'Background runspace completes without running on the caller thread' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null
    $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
        $callerThread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation ProgressDemo
        $allEvents = [System.Collections.Generic.List[object]]::new()
        $limit = [DateTime]::UtcNow.AddSeconds(12)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $limit) {
            foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $allEvents.Add($evt) }
            Start-Sleep -Milliseconds 50
        }
        foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $allEvents.Add($evt) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher) 'Operation exceeded test timeout'
        Assert-True (@($allEvents | Where-Object { $_.Type -eq 'Completed' -and $_.OperationId -eq $id }).Count -eq 1)
        $progress = @($allEvents | Where-Object { $_.Type -eq 'Progress' })
        Assert-True ($progress.Count -ge 8) 'Expected progress messages from worker'
        Assert-True ($progress[0].WorkerThreadId -ne $callerThread) 'Worker ran on the caller thread'
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0) {
            Request-OperationCancellation -Dispatcher $dispatcher
            $until = [DateTime]::UtcNow.AddSeconds(4)
            while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $until) {
                $null = @(Receive-DispatcherEvents -Dispatcher $dispatcher)
                Start-Sleep -Milliseconds 50
            }
        }
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Invoke-TestCase -Name 'Cancellation is observed and logger flushes the cancellation record' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null
    $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 1
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation ProgressDemo
        Start-Sleep -Milliseconds 450
        Request-OperationCancellation -Dispatcher $dispatcher -OperationId $id
        $all = [System.Collections.Generic.List[object]]::new()
        $until = [DateTime]::UtcNow.AddSeconds(6)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $until) {
            foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $all.Add($evt) }
            Start-Sleep -Milliseconds 50
        }
        foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $all.Add($evt) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Assert-True (@($all | Where-Object { $_.Type -eq 'Cancelled' }).Count -eq 1) 'Expected one Cancelled event'
        Close-WorkerDispatcher -Dispatcher $dispatcher
        $dispatcher = $null
        Stop-AppLogger -Logger $logger
        $logger = $null
        $log = [IO.File]::ReadAllText((Join-Path $scratch 'network-manager.log'))
        Assert-True ($log -match 'Cancelled ProgressDemo') 'Cancellation must be logged'
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Invoke-TestCase -Name 'Demo failure is reported to caller and does not crash dispatcher' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null
    $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 1
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation FailureDemo
        $events = [System.Collections.Generic.List[object]]::new()
        $until = [DateTime]::UtcNow.AddSeconds(5)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $until) {
            foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($evt) }
            Start-Sleep -Milliseconds 50
        }
        foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($evt) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Assert-True (@($events | Where-Object { $_.Type -eq 'Failed' -and $_.OperationId -eq $id }).Count -eq 1)
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Invoke-TestCase -Name 'Dispatcher rejects premature shutdown, then supports clean cancel and drain' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null; $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 1
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation ProgressDemo
        Assert-True ($id.Length -gt 0)
        Assert-Throws { Close-WorkerDispatcher -Dispatcher $dispatcher } 'Closing busy dispatcher should fail'
        Request-OperationCancellation -Dispatcher $dispatcher -OperationId 'nonexistent'
        Assert-Equal 1 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Request-OperationCancellation -Dispatcher $dispatcher -OperationId $id
        $limit = [DateTime]::UtcNow.AddSeconds(8)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $limit) {
            $null = @(Receive-DispatcherEvents -Dispatcher $dispatcher)
            Start-Sleep -Milliseconds 40
        }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher) 'Workers did not drain'
        Close-WorkerDispatcher -Dispatcher $dispatcher
        $dispatcher = $null
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Invoke-TestCase -Name 'Two concurrent workers each emit exactly one terminal event' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    $logger = $null; $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
        $one = Start-BackgroundOperation -Dispatcher $dispatcher -Operation ProgressDemo
        $two = Start-BackgroundOperation -Dispatcher $dispatcher -Operation FailureDemo
        $all = [System.Collections.Generic.List[object]]::new()
        $limit = [DateTime]::UtcNow.AddSeconds(12)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $limit) {
            foreach ($item in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $all.Add($item) }
            Start-Sleep -Milliseconds 40
        }
        foreach ($item in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $all.Add($item) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Assert-Equal 1 (@($all | Where-Object { $_.OperationId -eq $one -and $_.Type -eq 'Completed' }).Count)
        Assert-Equal 1 (@($all | Where-Object { $_.OperationId -eq $two -and $_.Type -eq 'Failed' }).Count)
        Assert-True (@($all | Where-Object { $_.OperationId -eq $one -and $_.Type -eq 'Progress' }).Count -ge 8)
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0) {
            Request-OperationCancellation -Dispatcher $dispatcher
            $limit = [DateTime]::UtcNow.AddSeconds(5)
            while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $limit) {
                $null = @(Receive-DispatcherEvents -Dispatcher $dispatcher)
                Start-Sleep -Milliseconds 50
            }
        }
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
    }
}

Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force

Invoke-TestCase -Name 'VCD worker fails safely with unset API URL without freezing dispatcher or accessing network' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vcd-noworker-' + [guid]::NewGuid().ToString('n'))
    $logger = $null; $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory (Join-Path $scratch 'logs') -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
        $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
        $cfg.vcd.apiUrl = '' # Never use a developer's configured live endpoint in tests.
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation 'VcdRead' -Arguments @{
            VcdConfiguration=$cfg.vcd; OutputDirectory=(Join-Path $scratch 'reports'); ConnectionOnly=$false
        }
        $events = [System.Collections.Generic.List[object]]::new()
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            foreach ($event in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($event) }
            Start-Sleep -Milliseconds 40
        }
        foreach ($event in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($event) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Assert-Equal 1 (@($events | Where-Object { $_.OperationId -eq $id -and $_.Type -eq 'Failed' }).Count)
        Assert-True (-not [IO.Directory]::Exists((Join-Path $scratch 'reports')))
    }
    finally {
        if ($null -ne $dispatcher) {
            if ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0) {
                Request-OperationCancellation -Dispatcher $dispatcher
                $deadline = [DateTime]::UtcNow.AddSeconds(4)
                while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
                    $null = @(Receive-DispatcherEvents -Dispatcher $dispatcher)
                    Start-Sleep -Milliseconds 40
                }
            }
            if ((Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
    }
}

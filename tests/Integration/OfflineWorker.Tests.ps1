Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force

Invoke-TestCase -Name 'Offline plan runs on actual background worker and emits HTML and JSON' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vcd-workerplan-' + [guid]::NewGuid().ToString('n'))
    $logger = $null; $dispatcher = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory (Join-Path $scratch 'logs') -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation OfflinePlan -Arguments @{
            StateRoot=(Join-Path $ProjectRoot 'examples\demo-state'); Environment='demo'; Scope='edge-gw-demo'; OutputDirectory=(Join-Path $scratch 'reports')
        }
        $events = [System.Collections.Generic.List[object]]::new()
        $limit = [DateTime]::UtcNow.AddSeconds(12)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $limit) {
            foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($evt) }
            Start-Sleep -Milliseconds 40
        }
        foreach ($evt in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($evt) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher) 'Offline worker timed out'
        $terminal = @($events | Where-Object { $_.OperationId -eq $id -and $_.Type -eq 'Completed' })
        Assert-Equal 1 $terminal.Count
        $summary = @($events | Where-Object { $_.OperationId -eq $id -and $_.Type -eq 'PlanSummary' })
        Assert-Equal 1 $summary.Count
        Assert-True ($summary[0].Message -match 'Create 3') 'Summary must contain plan results'
        Assert-Equal 1 @(Get-ChildItem (Join-Path $scratch 'reports') -Filter '*.json').Count
        Assert-Equal 1 @(Get-ChildItem (Join-Path $scratch 'reports') -Filter '*.html').Count
    }
    finally {
        if ($null -ne $dispatcher) {
            if ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0) {
                Request-OperationCancellation -Dispatcher $dispatcher
                $limit = [DateTime]::UtcNow.AddSeconds(5)
                while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $limit) {
                    $null = @(Receive-DispatcherEvents -Dispatcher $dispatcher)
                    Start-Sleep -Milliseconds 50
                }
            }
            if ((Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
    }
}

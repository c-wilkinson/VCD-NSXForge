Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force

Invoke-TestCase -Name 'Template saving runs from dispatcher through real worker and writes only local JSON' -Body {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('issue1-template-' + [guid]::NewGuid().ToString('n'))
    $dispatcher = $null; $logger = $null
    try {
        $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory (Join-Path $scratch 'logs') -MaximumBytes 5000000 -RetentionDays 30
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 1
        $templatePath = Join-Path $scratch 'user-templates.json'
        $rule = [pscustomobject]@{ name='Allow SQL';description='Test only';action='ALLOW';logging=$true;
            services=@([pscustomobject]@{protocol='TCP';ports=@('1433')}) }
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation 'SaveRuleTemplate' -Arguments @{
            Rule=$rule;TemplateName='SQL-Integration-Test';TemplatePath=$templatePath
            BuiltInPath=(Join-Path $ProjectRoot 'templates\firewall-rules.json')
        }
        $events=[System.Collections.Generic.List[object]]::new()
        $end=[DateTime]::UtcNow.AddSeconds(10)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $end) {
            foreach ($event in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($event) }
            Start-Sleep -Milliseconds 30
        }
        foreach ($event in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($event) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Assert-Equal 1 (@($events | Where-Object {$_.OperationId -eq $id -and $_.Type -eq 'Completed'}).Count)
        Assert-Equal 1 (@($events | Where-Object {$_.OperationId -eq $id -and $_.Type -eq 'SimulatorData' -and $_.Name -eq 'TemplateSaved'}).Count)
        Assert-True ([IO.File]::Exists($templatePath)) 'Template file must exist'
        $json = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
        Assert-Equal 'SQL-Integration-Test' ([string]$json.templates[0].name)
        Assert-Equal 'TCP' ([string]$json.templates[0].services[0].protocol)
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0) {
            Request-OperationCancellation -Dispatcher $dispatcher
            $end=[DateTime]::UtcNow.AddSeconds(5)
            while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $end) {
                $null=@(Receive-DispatcherEvents -Dispatcher $dispatcher)
                Start-Sleep -Milliseconds 30
            }
        }
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
    }
}

Invoke-TestCase -Name 'Cancellation warning appears once and actual post-cancellation worker failure stays Failed' -Body {
    # An intentionally non-cooperative test worker is isolated in a temporary fake project.
    # The dispatcher uses the real runspace engine and operation contract.
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('issue1-worker-' + [guid]::NewGuid().ToString('n'))
    $dispatcher = $null
    try {
        $dir = Join-Path $scratch 'src\Runtime'
        [void][IO.Directory]::CreateDirectory($dir)
        $worker = @'
param($Operation,$Arguments,$EventQueue,$Logger,[System.Threading.CancellationToken]$CancellationToken,$OperationId,$ApplicationRoot)
[System.Threading.Thread]::Sleep(2100)
throw 'Simulated I/O failure after cancellation; NOT an OperationCanceledException'
'@
        [IO.File]::WriteAllText((Join-Path $dir 'Invoke-WorkerOperation.ps1'),$worker)
        $dispatcher = New-WorkerDispatcher -ApplicationRoot $scratch -Logger ([pscustomobject]@{}) -MaximumWorkers 1 -CancellationWarningSeconds 1
        $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation ProgressDemo
        Request-OperationCancellation -Dispatcher $dispatcher -OperationId $id
        # A second cancellation request is idempotent.
        Request-OperationCancellation -Dispatcher $dispatcher -OperationId $id
        $events = [System.Collections.Generic.List[object]]::new()
        $end = [DateTime]::UtcNow.AddSeconds(8)
        while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $end) {
            foreach ($event in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($event) }
            Start-Sleep -Milliseconds 40
        }
        foreach ($event in @(Receive-DispatcherEvents -Dispatcher $dispatcher)) { $events.Add($event) }
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Assert-Equal 1 (@($events | Where-Object {$_.OperationId -eq $id -and $_.Type -eq 'CancellationDelayed'}).Count)
        Assert-Equal 1 (@($events | Where-Object {$_.OperationId -eq $id -and $_.Type -eq 'Failed'}).Count)
        Assert-Equal 0 (@($events | Where-Object {$_.OperationId -eq $id -and $_.Type -in @('Completed','Cancelled')}).Count)
    }
    finally {
        if ($null -ne $dispatcher -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
        if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
    }
}

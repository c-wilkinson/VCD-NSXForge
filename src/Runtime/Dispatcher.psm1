Set-StrictMode -Version Latest

function New-WorkerDispatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationRoot,
        [Parameter(Mandatory)]$Logger,
        [ValidateRange(1,8)][int]$MaximumWorkers = 3
    )
    $pool = [runspacefactory]::CreateRunspacePool(1, $MaximumWorkers)
    $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
    $pool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $pool.Open()
    [pscustomobject]@{
        ApplicationRoot = $ApplicationRoot
        Logger = $Logger
        Pool = $pool
        Events = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Jobs = [System.Collections.Generic.List[object]]::new()
    }
}

function Start-BackgroundOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Dispatcher,
        [Parameter(Mandatory)][ValidateSet('ProgressDemo','FailureDemo','OfflinePlan','VcdRead','SimulatorScopes','SimulatorLoadState','SimulatorPlan','SimulatorApply','SimulatorTraffic','SimulatorSaveDraft')][string]$Operation,
        [hashtable]$Arguments = @{}
    )
    $id = [guid]::NewGuid().ToString('n')
    $source = [System.Threading.CancellationTokenSource]::new()
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Dispatcher.Pool
    $scriptPath = Join-Path $Dispatcher.ApplicationRoot 'src\Runtime\Invoke-WorkerOperation.ps1'
    try {
        $scriptText = [IO.File]::ReadAllText($scriptPath)
        $null = $ps.AddScript($scriptText).AddArgument($Operation).AddArgument($Arguments).AddArgument($Dispatcher.Events).AddArgument($Dispatcher.Logger).AddArgument($source.Token).AddArgument($id).AddArgument($Dispatcher.ApplicationRoot)
        $handle = $ps.BeginInvoke()
        $Dispatcher.Jobs.Add([pscustomobject]@{
            Id = $id
            Name = $Operation
            PowerShell = $ps
            Handle = $handle
            Cancellation = $source
        })
    }
    catch {
        $ps.Dispose()
        $source.Dispose()
        throw
    }
    return $id
}

function Request-OperationCancellation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dispatcher, [string]$OperationId)
    foreach ($job in @($Dispatcher.Jobs.ToArray())) {
        if (-not $OperationId -or $job.Id -eq $OperationId) {
            $job.Cancellation.Cancel()
        }
    }
}

function Get-RunningOperationCount {
    param([Parameter(Mandatory)]$Dispatcher)
    return [int]$Dispatcher.Jobs.Count
}

function Receive-DispatcherEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dispatcher)
    $result = [System.Collections.Generic.List[object]]::new()
    $terminals = [System.Collections.Generic.List[object]]::new()
    $item = $null
    while ($Dispatcher.Events.TryDequeue([ref]$item)) {
        $result.Add($item)
        $item = $null
    }

    for ($index = $Dispatcher.Jobs.Count - 1; $index -ge 0; $index--) {
        $job = $Dispatcher.Jobs[$index]
        if (-not $job.Handle.IsCompleted) { continue }
        $outcome = 'Completed'
        $message = "$($job.Name) finished"
        try {
            # Only EndInvoke a completed asynchronous pipeline: never block the UI waiting for a worker.
            $null = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.HadErrors) {
                $outcome = 'Failed'
                $message = [string]$job.PowerShell.Streams.Error[0]
            }
        }
        catch {
            if ($job.Cancellation.IsCancellationRequested) {
                $outcome = 'Cancelled'
                $message = "$($job.Name) cancelled"
            }
            else {
                $outcome = 'Failed'
                $message = $_.Exception.Message
            }
        }
        finally {
            $job.PowerShell.Dispose()
            $job.Cancellation.Dispose()
            $Dispatcher.Jobs.RemoveAt($index)
        }
        $terminals.Add([pscustomobject]@{
            Type = $outcome
            OperationId = $job.Id
            Message = $message
            Percent = $null
        })
    }
    # Final worker progress must precede the terminal status for the same operation.
    while ($Dispatcher.Events.TryDequeue([ref]$item)) {
        $result.Add($item)
        $item = $null
    }
    foreach ($terminal in $terminals) { $result.Add($terminal) }
    return $result.ToArray()
}

function Close-WorkerDispatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dispatcher)
    if ($Dispatcher.Jobs.Count -gt 0) {
        throw 'Cannot close worker dispatcher while operations are running; cancel and drain first.'
    }
    $Dispatcher.Pool.Close()
    $Dispatcher.Pool.Dispose()
}

Export-ModuleMember -Function New-WorkerDispatcher, Start-BackgroundOperation, Request-OperationCancellation, Get-RunningOperationCount, Receive-DispatcherEvents, Close-WorkerDispatcher

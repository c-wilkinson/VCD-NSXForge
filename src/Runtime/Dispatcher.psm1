Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WorkerOperations.psm1') -ErrorAction Stop

function New-WorkerDispatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationRoot,
        [Parameter(Mandatory)]$Logger,
        [ValidateRange(1,8)][int]$MaximumWorkers = 3,
        [ValidateRange(1,3600)][int]$CancellationWarningSeconds = 15
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
        CancellationWarningSeconds = $CancellationWarningSeconds
        Closed = $false
    }
}

function Start-BackgroundOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Dispatcher,
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Arguments = @{}
    )
    if ($Dispatcher.Closed) { throw 'Worker dispatcher is closed.' }
    Confirm-WorkerOperationArguments -Operation $Operation -Arguments $Arguments
    $id = [guid]::NewGuid().ToString('n')
    $source = [System.Threading.CancellationTokenSource]::new()
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Dispatcher.Pool
    $scriptPath = Join-Path $Dispatcher.ApplicationRoot 'src\Runtime\Invoke-WorkerOperation.ps1'
    $job = [pscustomobject]@{
        Id = $id
        Name = $Operation
        PowerShell = $ps
        Handle = $null
        Cancellation = $source
        CancelRequestedUtc = $null
        WarningEmitted = $false
        CancellationObserved = $false
    }
    try {
        $scriptText = [IO.File]::ReadAllText($scriptPath)
        $null = $ps.AddScript($scriptText).AddArgument($Operation).AddArgument($Arguments).AddArgument($Dispatcher.Events).AddArgument($Dispatcher.Logger).AddArgument($source.Token).AddArgument($id).AddArgument($Dispatcher.ApplicationRoot)
        # Add the job before scheduling: a worker can finish immediately on another thread.
        $Dispatcher.Jobs.Add($job)
        $job.Handle = $ps.BeginInvoke()
    }
    catch {
        $null = $Dispatcher.Jobs.Remove($job)
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
            if (-not $job.Cancellation.IsCancellationRequested) {
                $job.CancelRequestedUtc = [DateTime]::UtcNow
                $job.Cancellation.Cancel()
            }
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
        if ($item.Type -eq 'WorkerCancellationObserved') {
            foreach ($job in @($Dispatcher.Jobs.ToArray())) {
                if ($job.Id -eq $item.OperationId) { $job.CancellationObserved = $true; break }
            }
        } else { $result.Add($item) }
        $item = $null
    }

    for ($index = $Dispatcher.Jobs.Count - 1; $index -ge 0; $index--) {
        $job = $Dispatcher.Jobs[$index]
        if (-not $job.Handle.IsCompleted) {
            # A warning is not a terminal event: the worker may still be executing.
            if ($null -ne $job.CancelRequestedUtc -and -not $job.WarningEmitted -and
                ([DateTime]::UtcNow - $job.CancelRequestedUtc).TotalSeconds -ge $Dispatcher.CancellationWarningSeconds) {
                $job.WarningEmitted = $true
                $result.Add([pscustomobject]@{
                    Type = 'CancellationDelayed'; OperationId = $job.Id
                    Message = 'Worker has not stopped after cancellation. It may still be writing local state; do not assume rollback. Wait or escalate to an operator.'
                    Percent = $null
                })
            }
            continue
        }
        $outcome = 'Completed'
        $message = "$($job.Name) finished"
        try {
            # Only EndInvoke a completed asynchronous pipeline: never block the UI waiting for a worker.
            $null = $job.PowerShell.EndInvoke($job.Handle)
            if ($job.PowerShell.HadErrors) {
                if ($job.CancellationObserved) {
                    $outcome = 'Cancelled'
                    $message = "$($job.Name) cancelled"
                }
                else {
                    $outcome = 'Failed'
                    $message = [string]$job.PowerShell.Streams.Error[0]
                }
            }
            elseif ($job.PowerShell.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Stopped) {
                $outcome = 'Cancelled'
                $message = "$($job.Name) stopped"
            }
        }
        catch {
            $errorValue = $_.Exception
            while ($null -ne $errorValue -and $errorValue -isnot [System.OperationCanceledException]) {
                $errorValue = $errorValue.InnerException
            }
            if ($null -ne $errorValue -or $job.CancellationObserved) {
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
    if ($Dispatcher.Closed) { return }
    $Dispatcher.Pool.Close()
    $Dispatcher.Pool.Dispose()
    $Dispatcher.Closed = $true
}

Export-ModuleMember -Function New-WorkerDispatcher, Start-BackgroundOperation, Request-OperationCancellation, Get-RunningOperationCount, Receive-DispatcherEvents, Close-WorkerDispatcher

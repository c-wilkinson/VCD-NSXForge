param(
    [string]$Operation,
    $Arguments,
    $EventQueue,
    $Logger,
    [System.Threading.CancellationToken]$CancellationToken,
    [string]$OperationId,
    [string]$ApplicationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ApplicationRoot 'src\Infrastructure\Logging\Logging.psm1') -Force

function Send-WorkerProgress {
    param([string]$Message, [int]$Percent)
    $EventQueue.Enqueue([pscustomobject]@{
        Type = 'Progress'
        OperationId = $OperationId
        Message = $Message
        Percent = $Percent
        WorkerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    })
}

Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'INFO' -OperationId $OperationId -Message "Started $Operation"
try {
    switch ($Operation) {
        'ProgressDemo' {
            for ($step = 1; $step -le 8; $step++) {
                $CancellationToken.ThrowIfCancellationRequested()
                Send-WorkerProgress -Message ("Simulated read-only step {0}/8" -f $step) -Percent ($step * 12)
                Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'INFO' -OperationId $OperationId -Message "Simulated step $step completed"
                for ($slice = 0; $slice -lt 5; $slice++) {
                    $CancellationToken.ThrowIfCancellationRequested()
                    [System.Threading.Thread]::Sleep(100)
                }
            }
            Send-WorkerProgress -Message 'Simulation finished' -Percent 100
        }
        'OfflinePlan' {
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Loading offline desired/applied/observed state' -Percent 15
            Import-Module (Join-Path $ApplicationRoot 'src\Application\Planning\OfflinePlan.psm1') -Force
            $plan = Get-OfflineNetworkPlan -StateRoot ([string]$Arguments.StateRoot) -Environment ([string]$Arguments.Environment) -Scope ([string]$Arguments.Scope)
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Building deterministic HTML and JSON reports' -Percent 65
            $reports = Export-OfflineNetworkPlan -Plan $plan -OutputDirectory ([string]$Arguments.OutputDirectory)
            $EventQueue.Enqueue([pscustomobject]@{
                Type = 'PlanSummary'; OperationId = $OperationId
                Message = ('{0}; blocked={1}; HTML={2}' -f $reports.Summary,$reports.Blocked,$reports.Html)
                Percent = 95; WorkerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            })
            Write-AppLog -Logger $Logger -Component 'OfflinePlan' -Level 'INFO' -OperationId $OperationId -Message ('Offline report written; blocked={0}' -f $reports.Blocked)
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Offline plan report created (no VCD calls)' -Percent 100
        }
        'VcdRead' {
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Discovering VCD API versions and authenticating' -Percent 10
            Import-Module (Join-Path $ApplicationRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force
            $parameters = @{
                VcdConfiguration = $Arguments.VcdConfiguration
                OutputDirectory = [string]$Arguments.OutputDirectory
                CancellationToken = $CancellationToken
                ConnectionOnly = [bool]$Arguments.ConnectionOnly
            }
            if ($Arguments.ContainsKey('Credential') -and $null -ne $Arguments.Credential) { $parameters.Credential = $Arguments.Credential }
            elseif ($Arguments.ContainsKey('BearerToken') -and $null -ne $Arguments.BearerToken) { $parameters.BearerToken = [string]$Arguments.BearerToken }
            # This operation is read-only; observed import is enabled only for explicit CLI use.
            $result = Invoke-VcdReadOperation @parameters
            $CancellationToken.ThrowIfCancellationRequested()
            $EventQueue.Enqueue([pscustomobject]@{
                Type = 'VcdSummary'; OperationId = $OperationId
                Message = ('VCD connection OK; snapshot={0}; rules={1}; IP Sets={2}; reservations={3}' -f $result.SnapshotPath,$result.FirewallRuleCount,$result.IpSetCount,$result.ReservationCount)
                Percent = 95; WorkerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            })
            Write-AppLog -Logger $Logger -Component 'VcdRead' -Level 'INFO' -OperationId $OperationId -Message 'Read-only VCD snapshot completed' -Properties @{ snapshot = $result.SnapshotPath }
            Send-WorkerProgress -Message 'Read-only VCD API snapshot complete' -Percent 100
        }
        'FailureDemo' {
            Send-WorkerProgress -Message 'Preparing simulated failure' -Percent 15
            [System.Threading.Thread]::Sleep(300)
            $CancellationToken.ThrowIfCancellationRequested()
            throw 'Deliberate demonstration failure; no VCD call was made.'
        }
        default { throw "Unsupported operation: $Operation" }
    }
    Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'INFO' -OperationId $OperationId -Message "Succeeded $Operation"
}
catch [System.OperationCanceledException] {
    Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'WARN' -OperationId $OperationId -Message "Cancelled $Operation"
    throw
}
catch {
    Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'ERROR' -OperationId $OperationId -Message ("Failed {0}: {1}" -f $Operation, $_.Exception.Message)
    throw
}

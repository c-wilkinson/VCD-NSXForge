param(
    $LogQueue,
    $Signal,
    $StopSource,
    $ErrorQueue,
    [string]$AppRoot,
    [string]$LogDirectory,
    [int]$MaximumBytes,
    [int]$RetentionDays
)

Set-StrictMode -Version Latest
. (Join-Path $AppRoot 'src\Infrastructure\Logging\Logging.File.ps1')
$session = $null
$nextRetentionCheck = [DateTime]::MinValue
try {
    $session = New-LogFileSession -Directory $LogDirectory -MaximumBytes $MaximumBytes
    while (-not $StopSource.IsCancellationRequested -or -not $LogQueue.IsEmpty) {
        $record = $null
        while ($LogQueue.TryDequeue([ref]$record)) {
            try {
                Write-LogFileRecord -Session $session -Record $record
            }
            catch {
                $ErrorQueue.Enqueue($_.Exception.Message)
                # File/disk problems must not crash the host UI. The next record retries.
            }
        }
        if ([DateTime]::UtcNow -ge $nextRetentionCheck) {
            try {
                Invoke-DailyLogRollover -Session $session
                Remove-ExpiredLogFiles -Directory $LogDirectory -RetentionDays $RetentionDays
            }
            catch { $ErrorQueue.Enqueue("Log retention error: $($_.Exception.Message)") }
            $nextRetentionCheck = [DateTime]::UtcNow.AddHours(1)
        }
        if (-not $StopSource.IsCancellationRequested) {
            $null = $Signal.Wait(200)
            $Signal.Reset()
        }
    }
}
catch {
    $ErrorQueue.Enqueue("Log writer stopped unexpectedly: $($_.Exception.Message)")
    throw
}
finally {
    if ($null -ne $session) { Close-LogFileSession -Session $session }
}

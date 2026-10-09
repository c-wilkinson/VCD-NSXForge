# Pure, WinForms-independent operation state machine: safe to unit test headless.
Set-StrictMode -Version Latest
function New-UiOperationState {
    [pscustomobject]@{ ActiveOperationId = ''; Phase = 'Idle'; Message = 'Ready'; Percent = 0; WorkerThreadId = '' }
}
function Set-UiOperationStarted {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$OperationId)
    if ($State.ActiveOperationId) { throw 'A UI operation is already active.' }
    if ([string]::IsNullOrWhiteSpace($OperationId)) { throw 'Operation ID must not be blank.' }
    $State.ActiveOperationId = $OperationId
    $State.Phase = 'Running'
    $State.Message = 'Operation queued on background runspace...'
    $State.Percent = 0
    $State.WorkerThreadId = ''
}
function Set-UiCancellationRequested {
    param([Parameter(Mandatory)]$State)
    if (-not $State.ActiveOperationId) { return $false }
    $State.Phase = 'Cancelling'
    $State.Message = 'Cancellation requested; waiting for worker...'
    return $true
}
function Update-UiOperationState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Event)
    if (-not $State.ActiveOperationId -or [string]$Event.OperationId -ne [string]$State.ActiveOperationId) { return $false }
    switch ([string]$Event.Type) {
        { $_ -in @('PlanSummary','VcdSummary') } {
            if ($State.Phase -eq 'Cancelling') { return $false }
            $State.Message = [string]$Event.Message
            $State.Percent = [Math]::Max(0, [Math]::Min(100, [int]$Event.Percent))
            return $true
        }
        'Progress' {
            if ($State.Phase -eq 'Cancelling') { return $false }
            $State.Message = [string]$Event.Message
            $State.Percent = [Math]::Max(0, [Math]::Min(100, [int]$Event.Percent))
            $State.WorkerThreadId = [string]$Event.WorkerThreadId
            return $true
        }
        { $_ -in @('Completed','Cancelled','Failed') } {
            $State.Phase = [string]$Event.Type
            $State.Message = ('{0}: {1}' -f $Event.Type, $Event.Message)
            if ($Event.Type -eq 'Completed') { $State.Percent = 100 }
            $State.ActiveOperationId = ''
            return $true
        }
        default { return $false }
    }
}
Export-ModuleMember -Function New-UiOperationState, Set-UiOperationStarted, Set-UiCancellationRequested, Update-UiOperationState

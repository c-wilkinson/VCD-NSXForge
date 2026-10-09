Import-Module (Join-Path $ProjectRoot 'src\Presentation\Controllers\UiState.psm1') -Force

Invoke-TestCase -Name 'UI state starts idle, starts work and disallows overlap' -Body {
    $state = New-UiOperationState
    Assert-Equal 'Idle' $state.Phase
    Set-UiOperationStarted -State $state -OperationId 'op1'
    Assert-Equal 'Running' $state.Phase
    Assert-Equal 'op1' $state.ActiveOperationId
    Assert-Throws { Set-UiOperationStarted -State $state -OperationId 'op2' }
}

Invoke-TestCase -Name 'UI state rejects late events, clamps progress and ignores other operation' -Body {
    $state = New-UiOperationState
    Set-UiOperationStarted -State $state -OperationId 'latest'
    $old = [pscustomobject]@{ Type='Completed'; OperationId='older'; Message='old'; Percent=100 }
    Assert-Equal $false (Update-UiOperationState -State $state -Event $old)
    Assert-Equal 'latest' $state.ActiveOperationId
    $progress = [pscustomobject]@{ Type='Progress'; OperationId='latest'; Message='step'; Percent=150; WorkerThreadId=42 }
    Assert-Equal $true (Update-UiOperationState -State $state -Event $progress)
    Assert-Equal 100 $state.Percent
    Assert-Equal '42' $state.WorkerThreadId
    Assert-Equal 'step' $state.Message
}

Invoke-TestCase -Name 'UI cancellation suppresses progress and permits terminal status' -Body {
    $state = New-UiOperationState
    Assert-Equal $false (Set-UiCancellationRequested -State $state)
    Set-UiOperationStarted -State $state -OperationId 'op'
    Assert-Equal $true (Set-UiCancellationRequested -State $state)
    Assert-Equal 'Cancelling' $state.Phase
    Assert-Equal $false (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type='Progress';OperationId='op';Message='stale';Percent=50}))
    Assert-Equal $true (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type='Cancelled';OperationId='op';Message='done'}))
    Assert-Equal 'Cancelled' $state.Phase
    Assert-Equal '' $state.ActiveOperationId
}

Invoke-TestCase -Name 'UI terminal statuses reset active operation; unknown events do not' -Body {
    foreach ($result in @('Completed','Failed','Cancelled')) {
        $state = New-UiOperationState
        Set-UiOperationStarted -State $state -OperationId 'op'
        Assert-Equal $false (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type='Unrecognised';OperationId='op';Message='bad'}))
        Assert-Equal $true (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type=$result;OperationId='op';Message='done'}))
        Assert-Equal $result $state.Phase
        Assert-Equal '' $state.ActiveOperationId
        if ($result -eq 'Completed') { Assert-Equal 100 $state.Percent }
        Assert-Equal $false (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type='Completed';OperationId='op';Message='again'}))
    }
}

Invoke-TestCase -Name 'UI state accepts plan summary only for its active operation' -Body {
    $state = New-UiOperationState
    Set-UiOperationStarted -State $state -OperationId 'newplan'
    Assert-True (-not (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type='PlanSummary';OperationId='oldplan';Message='stale';Percent=90})))
    Assert-True (Update-UiOperationState -State $state -Event ([pscustomobject]@{Type='PlanSummary';OperationId='newplan';Message='Plan ready';Percent=95}))
    Assert-Equal 'Plan ready' $state.Message
    Assert-Equal 95 $state.Percent
}

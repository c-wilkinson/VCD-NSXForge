Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\Controllers\UiState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NetworkEditorForm.psm1') -ErrorAction Stop

function New-NetworkManagerForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)]$Dispatcher,
        [Parameter(Mandatory)]$Logger
    )
    $form = [System.Windows.Forms.Form]::new()
    $form.Name = 'MainForm'
    $form.Text = if ($Configuration.vcd.mode -eq 'Simulator') { 'VCD Network Manager - Local Simulator' } else { 'VCD Network Manager - Read-only VCD' }
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = [System.Drawing.Size]::new(850, 620)
    $form.MinimumSize = [System.Drawing.Size]::new(880, 620)
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 10)
    $form.BackColor = [System.Drawing.Color]::White
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font

    $heading = [System.Windows.Forms.Label]::new()
    $heading.Text = 'Network Configuration Manager'
    $heading.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 17)
    $heading.SetBounds(24, 18, 780, 40)
    $heading.Anchor = 'Top, Left, Right'

    $subtitle = [System.Windows.Forms.Label]::new()
    $subtitle.Text = 'Target: VCD 10.6 | NSX-T | Windows PowerShell 5.1 | Configurable read-only VCD API'
    $subtitle.SetBounds(26, 62, 780, 26)
    $subtitle.ForeColor = [System.Drawing.Color]::DimGray
    $subtitle.Anchor = 'Top, Left, Right'

    $run = [System.Windows.Forms.Button]::new()
    $run.Name = 'RunDemoButton'
    $run.Text = 'Run background demo'
    $run.SetBounds(26, 111, 202, 37)
    $fail = [System.Windows.Forms.Button]::new()
    $fail.Name = 'FailureDemoButton'
    $fail.Text = 'Simulate failure'
    $fail.SetBounds(242, 111, 155, 37)
    $cancel = [System.Windows.Forms.Button]::new()
    $cancel.Name = 'CancelButton'
    $cancel.Text = 'Cancel operation'
    $cancel.SetBounds(411, 111, 166, 37)
    $cancel.Enabled = $false
    $planButton = [System.Windows.Forms.Button]::new()
    $planButton.Name = 'PlanDemoButton'
    $planButton.Text = 'Generate offline plan'
    $planButton.SetBounds(590, 111, 229, 37)
    $planButton.Anchor = 'Top, Right'

    $readVcdButton = [System.Windows.Forms.Button]::new()
    $readVcdButton.Name = 'ReadVcdButton'
    $readVcdButton.Text = 'Read VCD snapshot'
    $readVcdButton.SetBounds(26, 166, 202, 37)
    $editorButton=[System.Windows.Forms.Button]::new()
    $editorButton.Name='OpenNetworkEditorButton'
    $editorButton.Text='Network editor / traffic'
    $editorButton.SetBounds(245,166,195,37)
    $editorButton.Enabled=($Configuration.vcd.mode -ceq 'Simulator')
    $endpointLabel = [System.Windows.Forms.Label]::new()
    $endpointLabel.Name = 'VcdEndpointLabel'
    $endpointLabel.Text = if ($Configuration.vcd.apiUrl) { $(if ($Configuration.vcd.mode -eq 'Simulator') { 'SIMULATOR: ' } else { 'VCD API: ' }) + [string]$Configuration.vcd.apiUrl } else { 'VCD API: not configured (edit config/application.json)' }
    $endpointLabel.SetBounds(456, 174, 356, 25)
    $endpointLabel.ForeColor = [System.Drawing.Color]::DimGray
    $endpointLabel.Anchor = 'Top, Left, Right'

    $statusTitle = [System.Windows.Forms.Label]::new()
    $statusTitle.Text = 'Status'
    $statusTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 11)
    $statusTitle.SetBounds(26, 235, 240, 25)

    $status = [System.Windows.Forms.Label]::new()
    $status.Name = 'StatusLabel'
    $status.Text = 'Ready: choose a demonstration operation.'
    $status.SetBounds(26, 264, 790, 25)
    $status.Anchor = 'Top, Left, Right'

    $progress = [System.Windows.Forms.ProgressBar]::new()
    $progress.Name = 'ProgressBar'
    $progress.SetBounds(26, 296, 790, 20)
    $progress.Anchor = 'Top, Left, Right'
    $progress.Minimum = 0
    $progress.Maximum = 100

    $threadNote = [System.Windows.Forms.Label]::new()
    $threadNote.Name = 'ThreadLabel'
    $threadNote.Text = ('UI thread: {0} | Worker thread: not started | UI timer: 0 ticks' -f [System.Threading.Thread]::CurrentThread.ManagedThreadId)
    $threadNote.SetBounds(26, 328, 790, 24)
    $threadNote.ForeColor = [System.Drawing.Color]::DimGray
    $threadNote.Anchor = 'Top, Left, Right'

    $eventsHeading = [System.Windows.Forms.Label]::new()
    $eventsHeading.Text = 'Operation events (UI remains interactive)'
    $eventsHeading.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 11)
    $eventsHeading.SetBounds(26, 367, 765, 25)

    $events = [System.Windows.Forms.TextBox]::new()
    $events.Name = 'EventsTextBox'
    $events.Multiline = $true
    $events.ReadOnly = $true
    $events.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $events.SetBounds(26, 398, 790, 158)
    $events.Anchor = 'Top, Bottom, Left, Right'
    $events.Font = [System.Drawing.Font]::new('Consolas', 9)
    $events.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

    $footer = [System.Windows.Forms.Label]::new()
    $footer.Text = 'Live VCD remains read-only. Editing and flow monitoring affect LOCAL SYNTHETIC simulator data only.'
    $footer.SetBounds(26, 585, 795, 23)
    $footer.ForeColor = [System.Drawing.Color]::DimGray
    $footer.Anchor = 'Left, Right, Bottom'

    foreach ($control in @($heading,$subtitle,$run,$fail,$cancel,$planButton,$readVcdButton,$editorButton,$endpointLabel,$statusTitle,$status,$progress,$threadNote,$eventsHeading,$events,$footer)) {
        [void]$form.Controls.Add($control)
    }

    # Event handlers using GetNewClosure() execute in a new dynamic module.
    # Capture CommandInfo objects NOW, while all imported commands are visible,
    # rather than relying on PowerShell resolving module-scoped functions later.
    # This is necessary for UiState functions imported only into this form module.
    $commands = [pscustomobject]@{
        StartWorker    = Get-Command -Name 'Start-BackgroundOperation' -ErrorAction Stop
        CancelWorker   = Get-Command -Name 'Request-OperationCancellation' -ErrorAction Stop
        ReceiveEvents  = Get-Command -Name 'Receive-DispatcherEvents' -ErrorAction Stop
        CountWorkers   = Get-Command -Name 'Get-RunningOperationCount' -ErrorAction Stop
        WriteLog       = Get-Command -Name 'Write-AppLog' -ErrorAction Stop
        StartState     = Get-Command -Name 'Set-UiOperationStarted' -ErrorAction Stop
        CancelState    = Get-Command -Name 'Set-UiCancellationRequested' -ErrorAction Stop
        UpdateState    = Get-Command -Name 'Update-UiOperationState' -ErrorAction Stop
        EditorForm      = Get-Command -Name 'New-NetworkEditorForm' -ErrorAction Stop
    }

    $ui = New-UiOperationState
    $ui | Add-Member -NotePropertyName Closing -NotePropertyValue $false
    $ui | Add-Member -NotePropertyName Ticks -NotePropertyValue 0
    $ui | Add-Member -NotePropertyName UiThreadId -NotePropertyValue ([System.Threading.Thread]::CurrentThread.ManagedThreadId)
    $logEvent = {
        param([string]$text)
        if ($events.TextLength -gt 12000) {
            $events.Text = $events.Text.Substring($events.TextLength - 8000)
        }
        $events.AppendText(('{0}  {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $text, [Environment]::NewLine))
    }.GetNewClosure()

    $startOperation = {
        param([string]$name, [hashtable]$arguments = @{})
        if ($ui.Closing -or $ui.ActiveOperationId) { return }
        $id = ''
        try {
            $id = & $commands.StartWorker -Dispatcher $Dispatcher -Operation $name -Arguments $arguments
            & $commands.StartState -State $ui -OperationId $id
            $run.Enabled = $false
            $fail.Enabled = $false
            $planButton.Enabled = $false
            $readVcdButton.Enabled = $false
            $editorButton.Enabled = $false
            $cancel.Enabled = $true
            $progress.Value = 0
            $status.Text = 'Operation queued on background runspace...'
            & $logEvent ("Queued $name [id=$($ui.ActiveOperationId.Substring(0,8))]")
        }
        catch {
            $startupError = $_
            # Never leave an orphaned worker running if the state/UI update failed.
            if (-not [string]::IsNullOrEmpty([string]$id)) {
                try { & $commands.CancelWorker -Dispatcher $Dispatcher -OperationId $id }
                catch { & $logEvent ("Worker cancellation failed: $($_.Exception.Message)") }
            }
            $status.Text = 'Unable to start operation'
            $detail = $startupError.Exception.ToString()
            & $logEvent ("START ERROR: $detail")
            & $commands.WriteLog -Logger $Logger -Level 'ERROR' -Component 'WinForms' -Message 'Unable to start operation' -Properties @{ exceptionType = $startupError.Exception.GetType().FullName }
        }
    }.GetNewClosure()

    $run.Add_Click({ & $startOperation 'ProgressDemo' }.GetNewClosure())
    $fail.Add_Click({ & $startOperation 'FailureDemo' }.GetNewClosure())
    $planButton.Add_Click({
        $arguments = @{
            StateRoot = (Join-Path $Configuration.ApplicationRoot $Configuration.state.demoDirectory)
            Environment = [string]$Configuration.state.defaultEnvironment
            Scope = [string]$Configuration.state.defaultScope
            OutputDirectory = (Join-Path $Configuration.ApplicationRoot $Configuration.state.reportsDirectory)
        }
        & $startOperation 'OfflinePlan' $arguments
    }.GetNewClosure())
    $readVcdButton.Add_Click({
        if (-not $Configuration.vcd.apiUrl -or -not $Configuration.vcd.gatewayId) {
            $status.Text = 'Set vcd.apiUrl and vcd.gatewayId in config/application.json, then restart.'
            & $logEvent 'VCD configuration is incomplete; no connection attempted.'
            return
        }
        $simulatorMode = ($Configuration.vcd.PSObject.Properties.Name -contains 'mode' -and $Configuration.vcd.mode -ceq 'Simulator')
        if (-not $simulatorMode -and $Configuration.vcd.authentication -cne 'Credential') {
            $status.Text = 'WinForms supports Credential login; use tools/Invoke-VcdRead.ps1 for bearer tokens.'
            return
        }
        $credential = $null
        if (-not $simulatorMode) {
            $credential = Get-Credential -Message 'Enter VCD username@org and password for read-only access'
            if ($null -eq $credential) { return }
        }
        $vcdArguments = @{
            VcdConfiguration = $Configuration.vcd
            OutputDirectory = (Join-Path $Configuration.ApplicationRoot $Configuration.state.reportsDirectory)
            ConnectionOnly = $false
        }
        if (-not $simulatorMode) { $vcdArguments.Credential = $credential }
        & $startOperation 'VcdRead' $vcdArguments
        $credential = $null
    }.GetNewClosure())
    $editorButton.Add_Click({
        if ($ui.ActiveOperationId -or $ui.Closing) { return }
        $editor=$null
        try {
            $editor=& $commands.EditorForm -Configuration $Configuration -Logger $Logger
            $null=$editor.Form.ShowDialog($form)
        }
        catch { & $logEvent ('EDITOR ERROR: '+$_.Exception.Message);$status.Text='Unable to open editor' }
        finally {
            if ($null -ne $editor) {
                $editor.Timer.Stop();$editor.Timer.Dispose()
                try { & $editor.CloseCommand -Dispatcher $editor.Dispatcher }
                catch { & $logEvent ('Editor worker shutdown: '+$_.Exception.Message) }
                $editor.Form.Dispose()
            }
        }
    }.GetNewClosure())
    $cancel.Add_Click({
        if ($ui.ActiveOperationId) {
            & $commands.CancelWorker -Dispatcher $Dispatcher -OperationId $ui.ActiveOperationId
            $null = & $commands.CancelState -State $ui
            $cancel.Enabled = $false
            $status.Text = 'Cancellation requested; waiting for cooperative worker exit...'
            & $logEvent 'Cancellation requested'
        }
    }.GetNewClosure())

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = [int]$Configuration.runtime.uiPollMilliseconds
    $timer.Add_Tick({
        $ui.Ticks++
        $threadNote.Text = ('UI thread: {0} | Worker thread: {1} | UI timer: {2} ticks' -f $ui.UiThreadId, $ui.WorkerThreadId, $ui.Ticks)
        foreach ($item in @(& $commands.ReceiveEvents -Dispatcher $Dispatcher)) {
            # Only update controls for the currently active operation, never an old job.
            if (-not (& $commands.UpdateState -State $ui -Event $item)) { continue }
            $status.Text = $ui.Message
            $progress.Value = $ui.Percent
            if ($item.Type -in @('PlanSummary','VcdSummary')) {
                $kind = if ($item.Type -eq 'VcdSummary') { 'VCD' } else { 'PLAN' }
                & $logEvent ("$($kind): $($item.Message)")
            }
            elseif ($item.Type -eq 'Progress') {
                & $logEvent ("PROGRESS: $($item.Message)")
            }
            elseif ($item.Type -in @('Completed','Cancelled','Failed')) {
                & $logEvent ("$($item.Type.ToUpperInvariant()): $($item.Message)")
                $run.Enabled = -not $ui.Closing
                $fail.Enabled = -not $ui.Closing
                $planButton.Enabled = -not $ui.Closing
                $readVcdButton.Enabled = -not $ui.Closing
                $editorButton.Enabled = ($Configuration.vcd.mode -ceq 'Simulator' -and -not $ui.Closing)
                $cancel.Enabled = $false
            }
        }
        $writerError = ''
        while ($Logger.Errors.TryDequeue([ref]$writerError)) {
            & $logEvent ("LOGGING ERROR: $writerError")
            $writerError = ''
        }
        if ($ui.Closing -and (& $commands.CountWorkers -Dispatcher $Dispatcher) -eq 0) {
            $timer.Stop()
            $form.Close()
        }
    }.GetNewClosure())

    $form.Add_FormClosing({
        param($sender, $e)
        if ((& $commands.CountWorkers -Dispatcher $Dispatcher) -gt 0) {
            $e.Cancel = $true
            $ui.Closing = $true
            $run.Enabled = $false
            $fail.Enabled = $false
            $planButton.Enabled = $false
            $readVcdButton.Enabled = $false
            $editorButton.Enabled = $false
            $cancel.Enabled = $false
            $status.Text = 'Closing: cancelling active operations...'
            & $commands.CancelWorker -Dispatcher $Dispatcher
        }
    }.GetNewClosure())

    $form.Add_Shown({
        & $logEvent 'WinForms running on STA thread; workers run on an MTA runspace pool.'
        $timer.Start()
    }.GetNewClosure())
    # The caller owns form and timer disposal, after Application.Run returns.
    return [pscustomobject]@{ Form = $form; Timer = $timer }
}

Export-ModuleMember -Function New-NetworkManagerForm

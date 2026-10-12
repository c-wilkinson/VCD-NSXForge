# Engineer-facing landing dashboard. External I/O runs on dispatcher workers.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\Controllers\UiState.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NetworkEditorForm.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'VcdDiscoveryForm.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'VcdCapabilityForm.psm1') -ErrorAction Stop

function Set-NetworkDashboardBusyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Navigation,
        [Parameter(Mandatory)][object[]]$ActionSpecs,
        [Parameter(Mandatory)][System.Windows.Forms.Button]$ConnectionTest,
        [System.Windows.Forms.Button]$DiscoveryButton,
        [System.Windows.Forms.Button]$CapabilityButton,
        [Parameter(Mandatory)][System.Windows.Forms.Button]$CancelButton,
        [bool]$Busy,
        [bool]$Closing,
        [bool]$IsSimulator
    )
    foreach ($spec in $ActionSpecs) {
        $Navigation[$spec.Name].Enabled = (-not $Busy -and -not $Closing -and (-not $spec.Simulator -or $IsSimulator))
    }
    $ConnectionTest.Enabled = (-not $Busy -and -not $Closing)
    if ($null -ne $DiscoveryButton) { $DiscoveryButton.Enabled = (-not $Busy -and -not $Closing) }
    if ($null -ne $CapabilityButton) { $CapabilityButton.Enabled = (-not $Busy -and -not $Closing) }
    $CancelButton.Enabled = ($Busy -and -not $Closing)
    $CancelButton.Text = if ($Busy -and -not $Closing) { 'Cancel operation' } else { 'No active operation' }
}

function New-NetworkManagerForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)]$Dispatcher,
        [Parameter(Mandatory)]$Logger
    )

    $isSimulator = ([string]$Configuration.vcd.mode -ceq 'Simulator')
    $form = [System.Windows.Forms.Form]::new()
    $form.Name = 'MainForm'
    $form.Text = 'VCD-NSXForge | Network operations'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = [System.Drawing.Size]::new(1080, 780)
    $form.MinimumSize = [System.Drawing.Size]::new(1000, 735)
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 10)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.BackColor = [System.Drawing.SystemColors]::Control
    $form.ForeColor = [System.Drawing.SystemColors]::ControlText
    $form.KeyPreview = $true

    $root = [System.Windows.Forms.TableLayoutPanel]::new()
    $root.Name = 'DashboardLayout'
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.Padding = [System.Windows.Forms.Padding]::new(20, 10, 20, 10)
    $root.ColumnCount = 1
    $root.RowCount = 7
    foreach ($pixels in @(92, 116, 39, 266, 0, 82, 32)) {
        if ($pixels -eq 0) {
            [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
        } else {
            [void]$root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, $pixels))
        }
    }
    [void]$form.Controls.Add($root)

    $header = [System.Windows.Forms.TableLayoutPanel]::new()
    $header.Dock = 'Fill'; $header.ColumnCount = 2; $header.RowCount = 1
    [void]$header.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 70))
    [void]$header.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 30))
    $headerText = [System.Windows.Forms.Panel]::new(); $headerText.Dock = 'Fill'
    $title = [System.Windows.Forms.Label]::new()
    $title.Name = 'DashboardTitle'; $title.Text = 'VCD-NSXForge'
    $title.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 23)
    $title.Dock = 'Top'; $title.Height = 49
    $subtitle = [System.Windows.Forms.Label]::new()
    $subtitle.Text = 'Network configuration and security operations'
    $subtitle.Dock = 'Top'; $subtitle.Height = 30
    $subtitle.ForeColor = [System.Drawing.SystemColors]::GrayText
    # WinForms processes docked controls in reverse z-order.
    $headerText.Controls.Add($subtitle); $headerText.Controls.Add($title)
    $modePanel = [System.Windows.Forms.Panel]::new(); $modePanel.Dock = 'Fill'
    $mode = [System.Windows.Forms.Label]::new()
    $mode.Name = 'ConnectionModeLabel'
    $mode.Text = if ($isSimulator) { 'LOCAL SIMULATOR' } else { 'LIVE VCD  -  READ ONLY' }
    $mode.BackColor = if ($isSimulator) { [System.Drawing.Color]::FromArgb(218, 241, 226) } else { [System.Drawing.Color]::FromArgb(255, 235, 204) }
    $mode.ForeColor = [System.Drawing.Color]::FromArgb(29, 65, 48)
    $mode.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
    $mode.TextAlign = 'MiddleCenter'; $mode.Dock = 'Fill'
    $mode.Margin = [System.Windows.Forms.Padding]::new(12, 18, 3, 30)
    $modePanel.Padding = [System.Windows.Forms.Padding]::new(8, 16, 3, 30)
    $modePanel.Controls.Add($mode)
    $header.Controls.Add($headerText, 0, 0); $header.Controls.Add($modePanel, 1, 0)
    $root.Controls.Add($header, 0, 0)

    $connection = [System.Windows.Forms.TableLayoutPanel]::new()
    $connection.Name = 'ConnectionSummaryPanel'; $connection.Dock = 'Fill'
    $connection.ColumnCount = 2; $connection.RowCount = 1
    $connection.BorderStyle = 'FixedSingle'
    $connection.BackColor = [System.Drawing.SystemColors]::Window
    [void]$connection.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 78))
    [void]$connection.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 22))
    $connectionInfo = [System.Windows.Forms.TableLayoutPanel]::new()
    $connectionInfo.Dock = 'Fill'; $connectionInfo.RowCount = 3; $connectionInfo.ColumnCount = 1
    $connectionInfo.Padding = [System.Windows.Forms.Padding]::new(12, 5, 4, 4)
    [void]$connectionInfo.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 29))
    [void]$connectionInfo.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 35))
    [void]$connectionInfo.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
    $connectionTitle = [System.Windows.Forms.Label]::new()
    $connectionTitle.Text = 'CONNECTION AND TARGET'
    $connectionTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
    $connectionTitle.ForeColor = [System.Drawing.SystemColors]::GrayText
    $connectionTitle.Dock = 'Fill'
    $endpointLabel = [System.Windows.Forms.Label]::new()
    $endpointLabel.Name = 'VcdEndpointLabel'
    $endpointLabel.Text = if ($Configuration.vcd.apiUrl) { [string]$Configuration.vcd.apiUrl } else { 'Not configured - set vcd.apiUrl in config/application.json' }
    $endpointLabel.AutoEllipsis = $true; $endpointLabel.Dock = 'Fill'
    $endpointLabel.AccessibleName = 'Configured VCD API endpoint'
    $gatewayLabel = [System.Windows.Forms.Label]::new()
    $gatewayLabel.Name = 'ConfiguredGatewayLabel'
    $gatewayLabel.Text = if ($Configuration.vcd.gatewayId) { 'Gateway: ' + [string]$Configuration.vcd.gatewayId } else { 'Gateway: not configured' }
    $gatewayLabel.Dock = 'Fill'; $gatewayLabel.AutoEllipsis = $true
    $gatewayLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
    $connectionInfo.Controls.Add($connectionTitle, 0, 0)
    $connectionInfo.Controls.Add($endpointLabel, 0, 1)
    $connectionInfo.Controls.Add($gatewayLabel, 0, 2)
    $connectionTestPanel = [System.Windows.Forms.Panel]::new()
    $connectionTestPanel.Dock = 'Fill'
    $connectionTestPanel.Padding = [System.Windows.Forms.Padding]::new(5, 12, 15, 10)
    $connectionTest = [System.Windows.Forms.Button]::new()
    $connectionTest.Name = 'TestConnectionButton'; $connectionTest.Text = 'Test connection'
    $connectionTest.Dock = 'Fill'
    $connectionTest.AccessibleName = 'Test VMware Cloud Director API connection'
    $connectionActions = [System.Windows.Forms.TableLayoutPanel]::new()
    $connectionActions.Dock='Fill';$connectionActions.RowCount=3;$connectionActions.ColumnCount=1
    [void]$connectionActions.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 33.33))
    [void]$connectionActions.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 33.33))
    $discoverButton = [System.Windows.Forms.Button]::new()
    $discoverButton.Name = 'DiscoverVcdButton'; $discoverButton.Text = 'Browse infrastructure'
    $discoverButton.AccessibleName = 'Discover VCD organisations VDCs Edge Gateways and networks'
    $discoverButton.Dock='Fill';$discoverButton.Enabled=$true
    [void]$connectionActions.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 33.34))
    $capabilityButton = [System.Windows.Forms.Button]::new()
    $capabilityButton.Name='CheckVcdCompatibilityButton'
    $capabilityButton.Text='Check compatibility'
    $capabilityButton.AccessibleName='Inspect selected gateway compatibility and unsupported firewall features'
    $capabilityButton.Dock='Fill'
    $connectionActions.Controls.Add($connectionTest,0,0)
    $connectionActions.Controls.Add($discoverButton,0,1)
    $connectionActions.Controls.Add($capabilityButton,0,2)
    $connectionTestPanel.Controls.Add($connectionActions)
    $connection.Controls.Add($connectionInfo, 0, 0)
    $connection.Controls.Add($connectionTestPanel, 1, 0)
    $root.Controls.Add($connection, 0, 1)

    $sectionTitle = [System.Windows.Forms.Label]::new()
    $sectionTitle.Name = 'QuickActionsHeading'; $sectionTitle.Text = 'NETWORK OPERATIONS'
    $sectionTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
    $sectionTitle.ForeColor = [System.Drawing.SystemColors]::GrayText
    $sectionTitle.Dock = 'Fill'; $sectionTitle.TextAlign = 'BottomLeft'
    $root.Controls.Add($sectionTitle, 0, 2)

    $cards = [System.Windows.Forms.TableLayoutPanel]::new()
    $cards.Name = 'DashboardActions'; $cards.Dock = 'Fill'
    $cards.RowCount = 2; $cards.ColumnCount = 3
    for ($i = 0; $i -lt 3; $i++) {
        [void]$cards.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100.0 / 3.0))
    }
    for ($i = 0; $i -lt 2; $i++) { [void]$cards.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50)) }
    $root.Controls.Add($cards, 0, 3)

    $specs = @(
        [pscustomobject]@{ Name='FirewallRulesButton'; Text='Firewall rules'; Detail='Create, edit, reorder and review policies'; Tab='edgeFirewallRules'; Simulator=$true },
        [pscustomobject]@{ Name='IpSetsButton'; Text='IP Sets'; Detail='Manage reusable address groups'; Tab='ipSets'; Simulator=$true },
        [pscustomobject]@{ Name='IpReservationsButton'; Text='IP reservations'; Detail='Reserve or release network addresses'; Tab='manualIpReservations'; Simulator=$true },
        [pscustomobject]@{ Name='TrafficMonitorButton'; Text='Traffic analysis'; Detail='Synthetic flows and matched firewall rules'; Tab='traffic'; Simulator=$true },
        [pscustomobject]@{ Name='ChangePlansButton'; Text='Change plans'; Detail='Review drafts, drift and proposed changes'; Tab='plan'; Simulator=$true },
        [pscustomobject]@{ Name='ReadVcdButton'; Text='Refresh network snapshot'; Detail='Read current configuration using the API'; Tab=''; Simulator=$false }
    )
    $navigation = @{}
    $tooltips = [System.Windows.Forms.ToolTip]::new()
    foreach ($spec in $specs) {
        $index = $navigation.Count
        $card = [System.Windows.Forms.TableLayoutPanel]::new()
        $card.Dock = 'Fill'; $card.Margin = [System.Windows.Forms.Padding]::new(0, 0, 12, 12)
        $card.Padding = [System.Windows.Forms.Padding]::new(12, 12, 12, 6)
        $card.RowCount = 2; $card.ColumnCount = 1
        [void]$card.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 51))
        [void]$card.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
        $card.BorderStyle = 'FixedSingle'; $card.BackColor = [System.Drawing.SystemColors]::Window
        $button = [System.Windows.Forms.Button]::new()
        $button.Name = $spec.Name; $button.Text = $spec.Text
        $button.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 11)
        $button.Dock = 'Fill'; $button.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 7)
        $button.AccessibleName = $spec.Text
        $button.Enabled = (-not $spec.Simulator -or $isSimulator)
        $description = [System.Windows.Forms.Label]::new()
        $description.Text = $spec.Detail; $description.AutoEllipsis = $true
        $description.Dock = 'Fill'
        $description.ForeColor = [System.Drawing.SystemColors]::GrayText
        if ($spec.Simulator -and -not $isSimulator) {
            $tooltips.SetToolTip($button, 'Editing and traffic simulation require Local Simulator mode. Live VCD remains read-only.')
        }
        $card.Controls.Add($button, 0, 0)
        $card.Controls.Add($description, 0, 1)
        $cards.Controls.Add($card, $index % 3, [int][Math]::Floor($index / 3))
        $navigation[$spec.Name] = $button
    }

    $activityPanel = [System.Windows.Forms.Panel]::new()
    $activityPanel.Dock = 'Fill'; $activityPanel.Padding = [System.Windows.Forms.Padding]::new(0, 0, 0, 8)
    $activityHeading = [System.Windows.Forms.Label]::new()
    $activityHeading.Text = 'RECENT ACTIVITY'; $activityHeading.Dock = 'Top'; $activityHeading.Height = 27
    $activityHeading.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
    $activityHeading.ForeColor = [System.Drawing.SystemColors]::GrayText
    $events = [System.Windows.Forms.TextBox]::new()
    $events.Name = 'EventsTextBox'; $events.Dock = 'Fill'; $events.Multiline = $true
    $events.ReadOnly = $true; $events.ScrollBars = 'Vertical'; $events.WordWrap = $true
    $events.Font = [System.Drawing.Font]::new('Consolas', 9)
    $events.BackColor = [System.Drawing.SystemColors]::Window
    $events.AccessibleName = 'Recent network operation activity log'
    $activityPanel.Controls.Add($events)
    $activityPanel.Controls.Add($activityHeading)
    $root.Controls.Add($activityPanel, 0, 4)

    $operations = [System.Windows.Forms.TableLayoutPanel]::new()
    $operations.Name = 'OperationStatusPanel'; $operations.Dock = 'Fill'
    $operations.ColumnCount = 2; $operations.RowCount = 1
    $operations.BorderStyle = 'FixedSingle'; $operations.BackColor = [System.Drawing.SystemColors]::Window
    [void]$operations.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 80))
    [void]$operations.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 20))
    $statusStack = [System.Windows.Forms.TableLayoutPanel]::new()
    $statusStack.Dock = 'Fill'; $statusStack.ColumnCount = 1; $statusStack.RowCount = 2
    $statusStack.Padding = [System.Windows.Forms.Padding]::new(12, 7, 8, 7)
    [void]$statusStack.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50))
    [void]$statusStack.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 50))
    $status = [System.Windows.Forms.Label]::new()
    $status.Name = 'StatusLabel'; $status.Text = 'Ready. Select a network operation.'
    $status.Dock = 'Fill'; $status.AutoEllipsis = $true
    $status.AccessibleName = 'Current operation status'
    $progress = [System.Windows.Forms.ProgressBar]::new()
    $progress.Name = 'ProgressBar'; $progress.Dock = 'Fill'; $progress.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4)
    $progress.Minimum = 0; $progress.Maximum = 100
    $statusStack.Controls.Add($status, 0, 0)
    $statusStack.Controls.Add($progress, 0, 1)
    $cancelPanel = [System.Windows.Forms.Panel]::new()
    $cancelPanel.Dock = 'Fill'; $cancelPanel.Padding = [System.Windows.Forms.Padding]::new(5, 17, 12, 17)
    $cancel = [System.Windows.Forms.Button]::new()
    $cancel.Name = 'CancelOperationButton'; $cancel.Text = 'No active operation'; $cancel.Dock = 'Fill'
    $cancel.AccessibleName = 'Cancel current background operation'
    $cancel.AccessibleDescription = 'Only available while a network operation is running.'
    $cancel.Enabled = $false
    $cancelPanel.Controls.Add($cancel)
    $operations.Controls.Add($statusStack, 0, 0)
    $operations.Controls.Add($cancelPanel, 1, 0)
    $root.Controls.Add($operations, 0, 5)

    $footer = [System.Windows.Forms.Label]::new()
    $footer.Name = 'DashboardSafetyNotice'
    $footer.Text = if ($isSimulator) { 'SYNTHETIC DATA ONLY  |  Apply actions affect the local simulator, never workplace VCD.' } else { 'LIVE VCD READ ONLY  |  No direct firewall, IP Set or reservation writes are available.' }
    $footer.Dock = 'Fill'; $footer.TextAlign = 'MiddleLeft'
    $footer.ForeColor = [System.Drawing.SystemColors]::GrayText
    $root.Controls.Add($footer, 0, 6)

    # Resolve all cross-module commands before constructing event closures.
    $commands = [pscustomobject]@{
        StartWorker   = Get-Command -Name 'Start-BackgroundOperation' -ErrorAction Stop
        CancelWorker  = Get-Command -Name 'Request-OperationCancellation' -ErrorAction Stop
        ReceiveEvents = Get-Command -Name 'Receive-DispatcherEvents' -ErrorAction Stop
        CountWorkers  = Get-Command -Name 'Get-RunningOperationCount' -ErrorAction Stop
        WriteLog      = Get-Command -Name 'Write-AppLog' -ErrorAction Stop
        StartState    = Get-Command -Name 'Set-UiOperationStarted' -ErrorAction Stop
        CancelState   = Get-Command -Name 'Set-UiCancellationRequested' -ErrorAction Stop
        UpdateState   = Get-Command -Name 'Update-UiOperationState' -ErrorAction Stop
        EditorForm    = Get-Command -Name 'New-NetworkEditorForm' -ErrorAction Stop
        SetBusy       = Get-Command -Name 'Set-NetworkDashboardBusyState' -ErrorAction Stop
        DiscoveryForm = Get-Command -Name 'New-VcdDiscoverySelectionForm' -ErrorAction Stop
        CapabilityForm = Get-Command -Name 'New-VcdCapabilityReportForm' -ErrorAction Stop
    }
    $ui = New-UiOperationState
    $ui | Add-Member -NotePropertyName Closing -NotePropertyValue $false
    $ui | Add-Member -NotePropertyName Ticks -NotePropertyValue 0
    # Selected IDs are transient: do not modify config/application.json.
    $selectedTarget = @{ GatewayId = ''; NetworkIds = @(); OrgId = ''; VdcId = '' }

    $logEvent = {
        param([string]$text)
        if ($events.TextLength -gt 12000) { $events.Text = $events.Text.Substring($events.TextLength - 8000) }
        $events.AppendText(('{0}  {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $text, [Environment]::NewLine))
    }.GetNewClosure()

    $setBusy = {
        param([bool]$busy)
        & $commands.SetBusy -Navigation $navigation -ActionSpecs $specs `
            -ConnectionTest $connectionTest -DiscoveryButton $discoverButton -CapabilityButton $capabilityButton -CancelButton $cancel -Busy $busy `
            -Closing ([bool]$ui.Closing) -IsSimulator $isSimulator
    }.GetNewClosure()

    $startOperation = {
        param([string]$name, [hashtable]$arguments = @{})
        if ($ui.Closing -or $ui.ActiveOperationId) { return }
        $operationId = ''
        try {
            $operationId = & $commands.StartWorker -Dispatcher $Dispatcher -Operation $name -Arguments $arguments
            & $commands.StartState -State $ui -OperationId $operationId
            & $setBusy $true
            $progress.Value = 0
            $status.Text = 'Working: ' + $name
            & $logEvent "Queued $name"
        }
        catch {
            $startupError = $_
            if ($operationId) {
                try { & $commands.CancelWorker -Dispatcher $Dispatcher -OperationId $operationId }
                catch { & $logEvent ('Cancellation error: ' + $_.Exception.Message) }
            }
            $status.Text = 'Unable to start operation'
            & $logEvent ('START ERROR: ' + $startupError.Exception.Message)
            & $commands.WriteLog -Logger $Logger -Level 'ERROR' -Component 'Dashboard' -Message 'Unable to start operation'
            & $setBusy $false
        }
    }.GetNewClosure()

    $startVcdRead = {
        param([bool]$connectionOnly, [bool]$discoverOnly = $false, [bool]$capabilitiesOnly = $false)
        if ($ui.ActiveOperationId -or $ui.Closing) { return }
        $currentGatewayId = if ($selectedTarget.GatewayId) { $selectedTarget.GatewayId } else { [string]$Configuration.vcd.gatewayId }
        if (-not $Configuration.vcd.apiUrl -or (-not $connectionOnly -and -not $discoverOnly -and -not $currentGatewayId)) {
            $status.Text = 'Configure vcd.apiUrl (and a gateway for snapshots) in config/application.json, then restart.'
            & $logEvent 'API endpoint or gateway is not configured; no connection attempted.'
            return
        }
        if (-not $isSimulator -and $Configuration.vcd.authentication -cne 'Credential') {
            $status.Text = 'Use tools/Invoke-VcdRead.ps1 for bearer-token authentication.'
            return
        }
        $credential = $null
        if (-not $isSimulator) {
            $credential = Get-Credential -Message 'Read-only VMware Cloud Director authentication'
            if ($null -eq $credential) { return }
        }
        # Clone the non-secret settings, inserting runtime IDs only. The selected
        # target is never written to the application's configuration file.
        $vcdSettings = [pscustomobject]@{}
        foreach ($property in $Configuration.vcd.PSObject.Properties) {
            $vcdSettings | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
        if ($selectedTarget.GatewayId -and -not $discoverOnly) {
            $vcdSettings.gatewayId = $selectedTarget.GatewayId
            $vcdSettings.networkIds = @($selectedTarget.NetworkIds)
        }
        $args = @{
            VcdConfiguration = $vcdSettings
            OutputDirectory = (Join-Path $Configuration.ApplicationRoot $Configuration.state.reportsDirectory)
            ConnectionOnly = $connectionOnly
            DiscoverOnly = $discoverOnly
            CapabilitiesOnly = $capabilitiesOnly
        }
        if (-not $isSimulator) { $args.Credential = $credential }
        & $startOperation 'VcdRead' $args
        $credential = $null
    }.GetNewClosure()

    $openEditor = {
        param([string]$initialTab)
        if (-not $isSimulator -or $ui.Closing -or $ui.ActiveOperationId) { return }
        $editor = $null
        try {
            $editor = & $commands.EditorForm -Configuration $Configuration -Logger $Logger -InitialTab $initialTab
            $null = $editor.Form.ShowDialog($form)
            & $logEvent ('Closed ' + $initialTab + ' workspace')
        }
        catch {
            $status.Text = 'Unable to open network workspace'
            & $logEvent ('WORKSPACE ERROR: ' + $_.Exception.Message)
        }
        finally {
            if ($null -ne $editor) {
                $editor.Timer.Stop(); $editor.Timer.Dispose()
                try { & $editor.CloseCommand -Dispatcher $editor.Dispatcher }
                catch { & $logEvent ('Workspace shutdown error: ' + $_.Exception.Message) }
                $editor.Form.Dispose()
            }
        }
    }.GetNewClosure()

    foreach ($spec in $specs) {
        if ($spec.Simulator) {
            $selectedTab = [string]$spec.Tab
            $navigation[$spec.Name].Add_Click({ & $openEditor $selectedTab }.GetNewClosure())
        }
    }
    $navigation['ReadVcdButton'].Add_Click({ & $startVcdRead $false }.GetNewClosure())
    $connectionTest.Add_Click({ & $startVcdRead $true }.GetNewClosure())
    $discoverButton.Add_Click({ & $startVcdRead $false $true }.GetNewClosure())
    $capabilityButton.Add_Click({ & $startVcdRead $false $false $true }.GetNewClosure())
    $cancel.Add_Click({
        if ($ui.ActiveOperationId) {
            & $commands.CancelWorker -Dispatcher $Dispatcher -OperationId $ui.ActiveOperationId
            $null = & $commands.CancelState -State $ui
            $cancel.Enabled = $false
            $status.Text = 'Cancelling operation...'
            & $logEvent 'Cancellation requested'
        }
    }.GetNewClosure())

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = [int]$Configuration.runtime.uiPollMilliseconds
    $timer.Add_Tick({
        $ui.Ticks++
        foreach ($item in @(& $commands.ReceiveEvents -Dispatcher $Dispatcher)) {
            if ($item.Type -eq 'CancellationDelayed' -and $item.OperationId -eq $ui.ActiveOperationId) {
                $status.Text = 'Cancellation delayed - worker still active'
                & $logEvent ('WARNING: ' + $item.Message)
                continue
            }
            if (-not (& $commands.UpdateState -State $ui -Event $item)) { continue }
            $status.Text = $ui.Message
            $progress.Value = $ui.Percent
            if ($item.Type -eq 'VcdDiscovery') {
                & $logEvent $item.Message
                $dialog = $null
                try {
                    $dialog = & $commands.DiscoveryForm -Inventory $item.Payload
                    if ($dialog.Form.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                        $selectedTarget.GatewayId = $dialog.Selection.GatewayId
                        $selectedTarget.NetworkIds = @($dialog.Selection.NetworkIds)
                        $selectedTarget.OrgId = $dialog.Selection.OrgId
                        $selectedTarget.VdcId = $dialog.Selection.VdcId
                        $gatewayLabel.Text = ('Selected gateway: {0}; networks: {1}' -f $selectedTarget.GatewayId, @($selectedTarget.NetworkIds).Count)
                        & $logEvent ('Target selected (read only): ' + $selectedTarget.GatewayId)
                    }
                }
                catch { $status.Text = 'Unable to display discovery selection'; & $logEvent 'Unable to display discovery selection.' }
                finally { if ($null -ne $dialog) { $dialog.Form.Dispose() } }
            }
            elseif ($item.Type -eq 'VcdCapabilities') {
                & $logEvent $item.Message
                $reportDialog=$null
                try {
                    $reportDialog=& $commands.CapabilityForm -Report $item.Payload
                    $null=$reportDialog.Form.ShowDialog($form)
                }
                catch { $status.Text='Unable to display compatibility report'; & $logEvent 'Compatibility report UI error.' }
                finally { if ($null -ne $reportDialog) { $reportDialog.Form.Dispose() } }
            }
            elseif ($item.Type -in @('PlanSummary','VcdSummary')) {
                & $logEvent ($item.Type + ': ' + $item.Message)
            }
            elseif ($item.Type -eq 'Progress') { & $logEvent ('PROGRESS: ' + $item.Message) }
            elseif ($item.Type -in @('Completed','Cancelled','Failed')) {
                & $logEvent ($item.Type.ToUpperInvariant() + ': ' + $item.Message)
                & $setBusy $false
            }
        }
        $writerError = ''
        while ($Logger.Errors.TryDequeue([ref]$writerError)) {
            & $logEvent ('LOGGING ERROR: ' + $writerError)
            $writerError = ''
        }
        if ($ui.Closing -and (& $commands.CountWorkers -Dispatcher $Dispatcher) -eq 0) {
            $timer.Stop(); $form.Close()
        }
    }.GetNewClosure())

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ((& $commands.CountWorkers -Dispatcher $Dispatcher) -gt 0) {
            $eventArgs.Cancel = $true
            $ui.Closing = $true
            & $setBusy $true
            $cancel.Enabled = $false
            $status.Text = 'Closing: cancelling active operations...'
            & $commands.CancelWorker -Dispatcher $Dispatcher
        }
    }.GetNewClosure())
    $form.Add_Shown({
        $displayMode = if ($isSimulator) { 'local simulator' } else { 'live read-only' }
        & $logEvent ("Dashboard ready ($displayMode)")
        $timer.Start()
    }.GetNewClosure())
    return [pscustomobject]@{ Form = $form; Timer = $timer; UiState = $ui }
}

Export-ModuleMember -Function New-NetworkManagerForm, Set-NetworkDashboardBusyState

# Real WinForms smoke tests run only on Windows PowerShell 5.1 / STA.
# The application itself never calls VCD in this phase.
if ($RunUiTests -and [Environment]::UserInteractive -and $PSVersionTable.PSEdition -eq 'Desktop' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\MainForm.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force

    Invoke-TestCase -Name 'Administrator dashboard provides real workflows, remains responsive and blocks live writes' -Body {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
        $logger = $null; $dispatcher = $null; $window = $null
        try {
            $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
            $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
            $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
            # The CI test must never use a configured corporate endpoint.
            $cfg.vcd.apiUrl = ''; $cfg.vcd.gatewayId = ''; $cfg.vcd.mode = 'Live'
            $window = New-NetworkManagerForm -Configuration $cfg -Dispatcher $dispatcher -Logger $logger
            $form = $window.Form
            foreach ($name in @('DashboardLayout','DashboardTitle','ConnectionModeLabel','ConnectionSummaryPanel',
                     'ConfiguredGatewayLabel','TestConnectionButton','ReadVcdButton','EventsTextBox',
                     'StatusLabel','ProgressBar','CancelOperationButton','DashboardSafetyNotice')) {
                Assert-Equal 1 (@($form.Controls.Find($name, $true)).Count) "Missing dashboard control $name"
            }
            $mode = $form.Controls.Find('ConnectionModeLabel', $true)[0]
            Assert-True ($mode.Text -match 'READ ONLY') 'Live mode must be conspicuously read-only'
            $simButtons = @('FirewallRulesButton','IpSetsButton','IpReservationsButton','TrafficMonitorButton','ChangePlansButton')
            foreach ($name in $simButtons) {
                $button = $form.Controls.Find($name, $true)[0]
                Assert-True ($null -ne $button) "Missing $name"
                Assert-True (-not $button.Enabled) "Live configuration must not enable $name"
            }
            foreach ($oldName in @('RunDemoButton','FailureDemoButton','PlanDemoButton','ThreadLabel')) {
                Assert-Equal 0 @($form.Controls.Find($oldName, $true)).Count "Demo control $oldName is still exposed"
            }
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $before = $window.UiState.Ticks
            for ($i = 0; $i -lt 9; $i++) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 30
            }
            Assert-True ($window.UiState.Ticks -gt $before) 'Dashboard UI timer stopped processing messages'
            $status = $form.Controls.Find('StatusLabel', $true)[0]
            $form.Controls.Find('TestConnectionButton',$true)[0].PerformClick()
            Assert-True ($status.Text -match 'vcd.apiUrl') 'Unconfigured connection test must not request credentials or network access'
            $form.Controls.Find('ReadVcdButton',$true)[0].PerformClick()
            Assert-True ($status.Text -match 'vcd.apiUrl') 'Unconfigured snapshot must not request credentials or network access'
            Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        }
        finally {
            if ($null -ne $window) { $window.Timer.Stop(); $window.Timer.Dispose(); $window.Form.Dispose() }
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
            if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
        }
    }

    Invoke-TestCase -Name 'Dashboard Cancel enables only during work and cancels a real background runspace' -Body {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vcd-dashboard-cancel-' + [guid]::NewGuid().ToString('n'))
        $logger = $null; $dispatcher = $null; $window = $null
        try {
            $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
            $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 1
            $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
            $cfg.vcd.mode = 'Simulator'; $cfg.vcd.apiUrl = 'http://127.0.0.1:8765'
            $window = New-NetworkManagerForm -Configuration $cfg -Dispatcher $dispatcher -Logger $logger
            $form = $window.Form
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $cancel = $form.Controls.Find('CancelOperationButton',$true)[0]
            $connection = $form.Controls.Find('TestConnectionButton',$true)[0]
            Assert-True (-not $cancel.Enabled) 'Cancel must be disabled with no operation'
            Assert-True ($cancel.Text -match 'No active') 'Idle cancellation status should be clear'
            $specs = @(
                [pscustomobject]@{Name='FirewallRulesButton';Simulator=$true},
                [pscustomobject]@{Name='IpSetsButton';Simulator=$true},
                [pscustomobject]@{Name='IpReservationsButton';Simulator=$true},
                [pscustomobject]@{Name='TrafficMonitorButton';Simulator=$true},
                [pscustomobject]@{Name='ChangePlansButton';Simulator=$true},
                [pscustomobject]@{Name='ReadVcdButton';Simulator=$false}
            )
            $nav = @{}
            foreach ($spec in $specs) { $nav[$spec.Name] = $form.Controls.Find($spec.Name,$true)[0] }
            $id = Start-BackgroundOperation -Dispatcher $dispatcher -Operation 'ProgressDemo'
            $window.UiState.ActiveOperationId = $id
            $window.UiState.Phase = 'Running'
            Set-NetworkDashboardBusyState -Navigation $nav -ActionSpecs $specs -ConnectionTest $connection `
                -CancelButton $cancel -Busy $true -Closing $false -IsSimulator $true
            Assert-True ($cancel.Enabled -and $cancel.Visible) 'Cancel must be clickable while a job is running'
            Assert-True (-not $connection.Enabled) 'New connection checks must be disabled during an operation'
            $cancel.PerformClick()
            Assert-Equal 'Cancelling' $window.UiState.Phase
            Assert-True (-not $cancel.Enabled) 'Cancel button must disable after cancellation is requested'
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ($window.UiState.ActiveOperationId -and [DateTime]::UtcNow -lt $deadline) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 35
            }
            Assert-Equal '' $window.UiState.ActiveOperationId 'Cancellation never reached UI terminal state'
            Assert-Equal 'Cancelled' $window.UiState.Phase 'Dispatcher did not signal cancellation'
            Assert-True (-not $cancel.Enabled) 'Cancel must be disabled after operation finishes'
            Assert-True $connection.Enabled 'Connection check should be available again when idle'
        }
        finally {
            if ($null -ne $window) { $window.Timer.Stop(); $window.Timer.Dispose(); $window.Form.Dispose() }
            if ($null -ne $dispatcher) {
                if ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0) {
                    Request-OperationCancellation -Dispatcher $dispatcher
                    $deadline = [DateTime]::UtcNow.AddSeconds(6)
                    while ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
                        $null = @(Receive-DispatcherEvents -Dispatcher $dispatcher)
                        Start-Sleep -Milliseconds 35
                    }
                }
                if ((Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
            }
            if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
            if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
        }
    }

    Invoke-TestCase -Name 'Simulator dashboard shortcuts are visible and navigate to correct editor tabs' -Body {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
        $logger = $null; $dispatcher = $null; $window = $null
        try {
            $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
            $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
            $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
            $cfg.vcd.mode = 'Simulator'
            $cfg.vcd.apiUrl = 'http://127.0.0.1:8765'
            $window = New-NetworkManagerForm -Configuration $cfg -Dispatcher $dispatcher -Logger $logger
            $window.Form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($window.Form.Controls.Find('ConnectionModeLabel',$true)[0].Text -eq 'LOCAL SIMULATOR')
            foreach ($name in @('FirewallRulesButton','IpSetsButton','IpReservationsButton','TrafficMonitorButton','ChangePlansButton')) {
                $button = $window.Form.Controls.Find($name,$true)[0]
                Assert-True ($button.Enabled -and $button.Visible) "Shortcut not available: $name"
                $point = $window.Form.PointToClient($button.PointToScreen([System.Drawing.Point]::Empty))
                Assert-True ($point.X -ge 0 -and $point.Y -ge 0 -and ($point.X+$button.Width) -le $window.Form.ClientSize.Width -and ($point.Y+$button.Height) -le $window.Form.ClientSize.Height) "Shortcut clipped: $name"
            }
            $editor = $null
            try {
                Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkEditorForm.psm1') -ErrorAction Stop
                foreach ($target in @(@('edgeFirewallRules','Firewall rules'),@('ipSets','IP Sets'),@('manualIpReservations','IP reservations'),@('plan','Change plan'),@('traffic','Synthetic traffic'))) {
                    $editor = New-NetworkEditorForm -Configuration $cfg -Logger $logger -InitialTab $target[0]
                    $tabControl = $editor.Form.Controls.Find('NetworkEditorTabs',$true)[0]
                    Assert-Equal $target[1] $tabControl.SelectedTab.Text "Dashboard target $($target[0])"
                    $editor.Timer.Stop(); $editor.Timer.Dispose()
                    & $editor.CloseCommand -Dispatcher $editor.Dispatcher
                    $editor.Form.Dispose(); $editor = $null
                }
            }
            finally {
                if ($null -ne $editor) {
                    $editor.Timer.Stop(); $editor.Timer.Dispose()
                    & $editor.CloseCommand -Dispatcher $editor.Dispatcher
                    $editor.Form.Dispose()
                }
            }
        }
        finally {
            if ($null -ne $window) { $window.Timer.Stop(); $window.Timer.Dispose(); $window.Form.Dispose() }
            if ($null -ne $dispatcher) { Close-WorkerDispatcher -Dispatcher $dispatcher }
            if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
            if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
        }
    }
}
else {
    if ($RunUiTests) {
        Invoke-TestCase -Name 'WinForms UI smoke test requires interactive Windows PowerShell 5.1 STA' -Body {
            throw 'Requires an interactive Windows session: powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -IncludeUi'
        }
    }
    else { Skip-TestCase -Name 'WinForms interactive smoke test' -Because 'Opt-in using -IncludeUi on a Windows interactive STA session' }
}
# Phase 4 construction-only smoke test: no simulator server required, no HTTP calls.
if ($RunUiTests -and [Environment]::UserInteractive -and $PSVersionTable.PSEdition -eq 'Desktop' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    Invoke-TestCase -Name 'Simulator editor constructs all three resource editors and traffic monitoring controls offline' -Body {
        Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkEditorForm.psm1') -ErrorAction Stop
        $scratch=Join-Path ([IO.Path]::GetTempPath()) ('vcd-ui4-'+[guid]::NewGuid().ToString('n'))
        $logger=$null;$window=$null
        try {
            $logger=Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
            $cfg=Read-AppConfiguration -ApplicationRoot $ProjectRoot
            $cfg.vcd.mode='Simulator';$cfg.vcd.apiUrl='http://127.0.0.1:8765'
            $window=New-NetworkEditorForm -Configuration $cfg -Logger $logger
            foreach ($controlName in @('ScopeSelector','ActorSelector','edgeFirewallRulesList','edgeFirewallRulesAddButton','edgeFirewallRulesEditButton','edgeFirewallRulesRemoveButton','edgeFirewallRulesUpButton','edgeFirewallRulesDownButton','ipSetsList','manualIpReservationsList','ApplySimulatorButton','GeneratePlanButton','PlanDiffDetails','SimulateFlowButton','TrafficEvents')) {
                Assert-True ($window.Form.Controls.Find($controlName,$true).Count -eq 1) "Missing editor control: $controlName"
            }
            Assert-True (-not $window.Form.Controls.Find('ApplySimulatorButton',$true)[0].Enabled)
            foreach ($name in @('edgeFirewallRulesAddButton','ipSetsAddButton','manualIpReservationsAddButton')) {
                $add=$window.Form.Controls.Find($name,$true)[0]
                Assert-True ($add.Parent -is [System.Windows.Forms.FlowLayoutPanel]) "Toolbar not permanently visible for $name"
                Assert-True ($add.Text.StartsWith('Add ')) "Add action lacks a clear engineer-facing label: $name"
            }
            Assert-True ($window.Form.Controls.Find('edgeFirewallRulesList',$true)[0] -is [System.Windows.Forms.DataGridView])
        }
        finally {
            if ($null -ne $window) {
                $window.Timer.Stop();$window.Timer.Dispose()
                & $window.CloseCommand -Dispatcher $window.Dispatcher
                $window.Form.Dispose()
            }
            if ($null -ne $logger) { Stop-AppLogger -Logger $logger }
            if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch,$true) }
        }
    }
}

# User-facing form contract: no JSON text areas; all controls present before showing modal UI.
if ($RunUiTests -and [Environment]::UserInteractive -and $PSVersionTable.PSEdition -eq 'Desktop' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    Invoke-TestCase -Name 'Network engineer dialogs expose labelled firewall IP Set and reservation controls' -Body {
        Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkItemDialog.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -ErrorAction Stop
        $docs=[ordered]@{edgeFirewallRules=(New-EmptyNetworkDocument edgeFirewallRules);ipSets=(New-EmptyNetworkDocument ipSets);manualIpReservations=(New-EmptyNetworkDocument manualIpReservations)}
        foreach ($kind in @('edgeFirewallRules','ipSets','manualIpReservations')) {
            $dialog=New-NetworkItemDialog -ResourceKind $kind -Documents $docs -NetworkId 'urn:vcloud:network:synthetic'
            try {
                Assert-True ($null -ne $dialog.Form.Controls.Find('SaveNetworkItemButton',$true)[0]) "Missing save for $kind"
                Assert-True ($null -ne $dialog.Form.Controls.Find('NetworkItemKey',$true)[0]) "Missing stable key for $kind"
                Assert-Equal 0 @($dialog.Form.Controls.Find('JsonEditor',$true)).Count
                if ($kind -eq 'edgeFirewallRules') {
                    foreach ($name in @('NetworkItemName','NetworkItemAction','NetworkItemEnabled','NetworkItemLogging','NetworkItemSources','NetworkItemDestinations','NetworkItemServices','NetworkItemAddService')) {
                        Assert-True ($null -ne $dialog.Form.Controls.Find($name,$true)[0]) "Missing firewall editor: $name"
                    }
                }
                elseif ($kind -eq 'ipSets') { Assert-True ($null -ne $dialog.Form.Controls.Find('NetworkItemAddresses',$true)[0]) }
                else { Assert-True ($null -ne $dialog.Form.Controls.Find('NetworkItemAddress',$true)[0]) }
            }
            finally { $dialog.Form.Dispose() }
        }
    }
}

# Regression tests for the dialog footer and Save event, run only in STA WinForms.
if ($RunUiTests -and [Environment]::UserInteractive -and $PSVersionTable.PSEdition -eq 'Desktop' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {

    # Controls.Find returns an empty array on failure. Don't index blindly:
    # report the resource type and actual missing control in NUnit XML.
    function Get-RequiredDialogTestControl {
        param([Parameter(Mandatory)][System.Windows.Forms.Form]$Form,
              [Parameter(Mandatory)][string]$Name,
              [Parameter(Mandatory)][string]$ResourceKind)
        $found=@($Form.Controls.Find($Name,$true))
        if ($found.Count -ne 1) { throw "Expected one '$Name' in $ResourceKind dialog, found $($found.Count)." }
        return $found[0]
    }

    Invoke-TestCase -Name 'Resource dialogs show Save and Cancel on screen, even at minimum size' -Body {
        Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkItemDialog.psm1') -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -ErrorAction Stop
        $docs=[ordered]@{edgeFirewallRules=(New-EmptyNetworkDocument edgeFirewallRules);ipSets=(New-EmptyNetworkDocument ipSets);manualIpReservations=(New-EmptyNetworkDocument manualIpReservations)}
        foreach ($kind in @('edgeFirewallRules','ipSets','manualIpReservations')) {
            $dialog=$null
            try {
                $dialog=New-NetworkItemDialog -ResourceKind $kind -Documents $docs -NetworkId 'urn:vcloud:network:synthetic'
                $dialog.Form.Size=$dialog.Form.MinimumSize
                $dialog.Form.Show()
                [System.Windows.Forms.Application]::DoEvents()
                $save=Get-RequiredDialogTestControl -Form $dialog.Form -Name 'SaveNetworkItemButton' -ResourceKind $kind
                $cancel=Get-RequiredDialogTestControl -Form $dialog.Form -Name 'CancelNetworkItemButton' -ResourceKind $kind
                $footer=$dialog.Footer
                $root=$dialog.Root
                Assert-True ($root -is [System.Windows.Forms.TableLayoutPanel]) "Missing explicit dialog layout for $kind"
                Assert-True ($footer -is [System.Windows.Forms.TableLayoutPanel]) "Missing fixed footer for $kind"
                Assert-Equal 'NetworkItemFooter' $footer.Name
                Assert-Equal 'NetworkItemRootLayout' $root.Name
                Assert-True ([object]::ReferenceEquals($root.Parent,$dialog.Form)) "Root detached from form in $kind"
                Assert-True ([object]::ReferenceEquals($footer.Parent,$root)) "Footer detached from root in $kind"
                Assert-True ([object]::ReferenceEquals($save,$dialog.SaveButton)) "Save button does not belong to dialog in $kind"
                Assert-True ([object]::ReferenceEquals($cancel,$dialog.CancelButton)) "Cancel button does not belong to dialog in $kind"
                foreach ($button in @($save,$cancel)) {
                    Assert-True ($button.Visible -and $button.Enabled) "Action '$($button.Name)' is hidden or disabled in $kind"
                    $topLeft=$dialog.Form.PointToClient($button.PointToScreen([System.Drawing.Point]::Empty))
                    Assert-True ($topLeft.X -ge 0 -and $topLeft.Y -ge 0 -and
                        ($topLeft.X+$button.Width) -le $dialog.Form.ClientSize.Width -and
                        ($topLeft.Y+$button.Height) -le $dialog.Form.ClientSize.Height) "Action '$($button.Name)' is outside visible $kind dialog: position=$topLeft, size=$($button.Size), client=$($dialog.Form.ClientSize)"
                }
                Assert-True ([object]::ReferenceEquals($dialog.Form.AcceptButton,$save)) "Enter should activate Save for $kind"
                Assert-True ([object]::ReferenceEquals($dialog.Form.CancelButton,$cancel)) "Escape should activate Cancel for $kind"
                $cancel.PerformClick()
                [System.Windows.Forms.Application]::DoEvents()
                Assert-True ($null -eq $dialog.Result.Value) "Cancel must not generate an item for $kind"
            }
            catch { throw "Dialog type ${kind}: $($_.Exception.Message)" }
            finally { if ($null -ne $dialog) { $dialog.Form.Dispose() } }
        }
    }

    Invoke-TestCase -Name 'WinForms Save creates and edits a firewall rule, validation does not close the dialog' -Body {
        Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkItemDialog.psm1') -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop
        $docs=[ordered]@{edgeFirewallRules=(New-EmptyNetworkDocument edgeFirewallRules);ipSets=(New-EmptyNetworkDocument ipSets);manualIpReservations=(New-EmptyNetworkDocument manualIpReservations)}
        $create=New-NetworkItemDialog -ResourceKind edgeFirewallRules -Documents $docs
        try {
            $create.Form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $save=Get-RequiredDialogTestControl -Form $create.Form -Name 'SaveNetworkItemButton' -ResourceKind edgeFirewallRules
            $validation=Get-RequiredDialogTestControl -Form $create.Form -Name 'NetworkItemValidation' -ResourceKind edgeFirewallRules
            $save.PerformClick()
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($null -eq $create.Result.Value) 'Invalid rule must not be accepted'
            Assert-True $create.Form.Visible 'Validation failure closed the dialog'
            Assert-True (-not [string]::IsNullOrWhiteSpace($validation.Text)) "Validation failure did not display inline feedback: $($validation.AccessibleDescription)"
            Assert-True ($validation.Text -notmatch "property 'Text' cannot be found") 'Validation caused a PowerShell automatic-variable exception'
            (Get-RequiredDialogTestControl -Form $create.Form -Name 'NetworkItemName' -ResourceKind edgeFirewallRules).Text='Allow HTTPS'
            $save.PerformClick()
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($null -ne $create.Result.Value) "Save did not return the new rule. Validation: $($validation.Text)"
            Assert-Equal 'allow-https' $create.Result.Value.key
            Assert-Equal 'ALLOW' $create.Result.Value.action
        }
        finally { $create.Form.Dispose() }
        Assert-Equal 0 @($docs.edgeFirewallRules.items).Count 'The dialog must not mutate baseline documents before the caller accepts the result'
        $docs=Set-NetworkDraftItem -Documents $docs -ResourceKind edgeFirewallRules -Item $create.Result.Value -Create
        $edit=New-NetworkItemDialog -ResourceKind edgeFirewallRules -Documents $docs -Original $create.Result.Value
        try {
            $edit.Form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            # A successful Save closes the modeless test form. Check control
            # ownership while the dialog is open, then assert returned data.
            $editValidation=$edit.ValidationLabel
            Assert-True ($editValidation -is [System.Windows.Forms.Label]) 'Edit dialog validation control is not a label'
            Assert-Equal 'NetworkItemValidation' $editValidation.Name
            Assert-True ([object]::ReferenceEquals($editValidation.Parent,$edit.Footer)) 'Edit validation label is not in its footer before Save'
            (Get-RequiredDialogTestControl -Form $edit.Form -Name 'NetworkItemName' -ResourceKind edgeFirewallRules).Text='Allow HTTPS (updated)'
            (Get-RequiredDialogTestControl -Form $edit.Form -Name 'SaveNetworkItemButton' -ResourceKind edgeFirewallRules).PerformClick()
            [System.Windows.Forms.Application]::DoEvents()
            $editFailure=if ($null -eq $edit.Result.Value) { $editValidation.Text } else { '' }
            Assert-True ($null -ne $edit.Result.Value) "Edit Save did not return updated item. Validation: $editFailure"
            Assert-Equal 'Allow HTTPS (updated)' $edit.Result.Value.name
            Assert-Equal 'allow-https' $edit.Result.Value.key
            Assert-Equal 'Allow HTTPS' $docs.edgeFirewallRules.items[0].name 'Editing must leave baseline unchanged until parent accepts result'
        }
        finally { $edit.Form.Dispose() }
    }
}

# Real WinForms smoke tests run only on Windows PowerShell 5.1 / STA.
# The application itself never calls VCD in this phase.
if ($RunUiTests -and [Environment]::UserInteractive -and $PSVersionTable.PSEdition -eq 'Desktop' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\MainForm.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force

    Invoke-TestCase -Name 'WinForms constructs and remains responsive during background processing' -Body {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
        $logger = $null; $dispatcher = $null; $window = $null
        try {
            $logger = Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
            $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $logger -MaximumWorkers 2
            $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
            # Smoke tests must not contact or prompt for a configured real VCD host.
            $cfg.vcd.apiUrl = ''
            $cfg.vcd.gatewayId = ''
            $cfg.vcd.mode='Live'
            $window = New-NetworkManagerForm -Configuration $cfg -Dispatcher $dispatcher -Logger $logger
            $editorButton=$window.Form.Controls.Find('OpenNetworkEditorButton',$true)[0]
            Assert-True ($null -ne $editorButton) 'Missing simulator editor control'
            Assert-True (-not $editorButton.Enabled) 'Simulator editor must be disabled in live mode'
            $window.Form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $button = $window.Form.Controls.Find('RunDemoButton', $true)[0]
            $status = $window.Form.Controls.Find('StatusLabel', $true)[0]
            $ticks = $window.Form.Controls.Find('ThreadLabel', $true)[0]
            $eventsBox = $window.Form.Controls.Find('EventsTextBox', $true)[0]
            Assert-True ($null -ne $button)
            Assert-True ($null -ne $eventsBox) 'EventsTextBox must be discoverable for diagnostics'
            $button.PerformClick()
            $before = $ticks.Text
            $deadline = [DateTime]::UtcNow.AddSeconds(12)
            while ([DateTime]::UtcNow -lt $deadline -and ((Get-RunningOperationCount -Dispatcher $dispatcher) -gt 0 -or $button.Enabled -eq $false)) {
                [System.Windows.Forms.Application]::DoEvents()
                [System.Threading.Thread]::Sleep(30)
            }
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($status.Text -match '^Completed:') "Unexpected UI status: $($status.Text); events: $($eventsBox.Text); worker jobs: $(Get-RunningOperationCount -Dispatcher $dispatcher)"
            Assert-True ($ticks.Text -ne $before) 'UI timer failed to tick during background execution'
            Assert-True $button.Enabled 'Run button did not become enabled again'

            $planButton = $window.Form.Controls.Find('PlanDemoButton', $true)[0]
            Assert-True ($null -ne $planButton) 'Missing Phase 2 offline-plan button'
            $planButton.PerformClick()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $deadline -and -not $planButton.Enabled) {
                [System.Windows.Forms.Application]::DoEvents()
                [System.Threading.Thread]::Sleep(30)
            }
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($status.Text -match '^Completed:') "Offline plan UI failed: $($status.Text); events: $($eventsBox.Text)"
            Assert-True ($eventsBox.Text -match 'PLAN: .*HTML=') 'Report path missing from UI event log'

            $vcdButton = $window.Form.Controls.Find('ReadVcdButton', $true)[0]
            Assert-True ($null -ne $vcdButton) 'Missing Phase 3 read-only VCD button'
            $vcdButton.PerformClick()
            Assert-True ($status.Text -match 'vcd.apiUrl') 'Unconfigured endpoint should not start HTTP or prompt for credentials'
            Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)

            $failureButton = $window.Form.Controls.Find('FailureDemoButton', $true)[0]
            $failureButton.PerformClick()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ([DateTime]::UtcNow -lt $deadline -and -not $failureButton.Enabled) {
                [System.Windows.Forms.Application]::DoEvents()
                [System.Threading.Thread]::Sleep(30)
            }
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($status.Text -match '^Failed:') "UI failure path did not update status: $($status.Text); events: $($eventsBox.Text)"

            $button.PerformClick()
            [System.Windows.Forms.Application]::DoEvents()
            $cancelButton = $window.Form.Controls.Find('CancelButton', $true)[0]
            $cancelButton.PerformClick()
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline -and -not $button.Enabled) {
                [System.Windows.Forms.Application]::DoEvents()
                [System.Threading.Thread]::Sleep(30)
            }
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($status.Text -match '^Cancelled:') "UI cancellation path did not update status: $($status.Text); events: $($eventsBox.Text)"
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
        # Force-refresh the dialog module once per test run to avoid stale imports
        # when rerunning tests in an existing Windows PowerShell session.
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
            # The recursive Controls.Find lookup failed for the empty validation label
            # on Windows PowerShell 5.1. The dialog exposes the exact control
            # used by the Save handler, so assert on that instance directly.
            $validation=$create.ValidationLabel
            Assert-True ($validation -is [System.Windows.Forms.Label]) 'Create dialog did not expose its validation label'
            Assert-Equal 'NetworkItemValidation' $validation.Name
            Assert-True ([object]::ReferenceEquals($validation.Parent,$create.Footer)) 'Validation label is not attached to the visible footer'
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
            # Check the live dialog layout BEFORE Save: successful Save closes
            # the modeless form used by this test, which disposes its controls
            # and can clear Parent references. Post-save tests inspect data.
            $validation=$edit.ValidationLabel
            Assert-True ($validation -is [System.Windows.Forms.Label]) 'Edit dialog did not expose its validation label'
            Assert-Equal 'NetworkItemValidation' $validation.Name
            Assert-True ([object]::ReferenceEquals($validation.Parent,$edit.Footer)) 'Edited rule validation label is not in the footer before Save'
            (Get-RequiredDialogTestControl -Form $edit.Form -Name 'NetworkItemName' -ResourceKind edgeFirewallRules).Text='Allow HTTPS (updated)'
            (Get-RequiredDialogTestControl -Form $edit.Form -Name 'SaveNetworkItemButton' -ResourceKind edgeFirewallRules).PerformClick()
            [System.Windows.Forms.Application]::DoEvents()
            Assert-True ($null -ne $edit.Result.Value) "Edit Save did not return updated item. Validation: $($validation.Text)"
            Assert-Equal 'Allow HTTPS (updated)' $edit.Result.Value.name
            Assert-Equal 'allow-https' $edit.Result.Value.key
            Assert-Equal 'Allow HTTPS' $docs.edgeFirewallRules.items[0].name 'Editing must leave baseline unchanged until parent accepts result'
        }
        finally { $edit.Form.Dispose() }
    }
}

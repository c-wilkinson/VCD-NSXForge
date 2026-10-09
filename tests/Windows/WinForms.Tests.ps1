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
            $window = New-NetworkManagerForm -Configuration $cfg -Dispatcher $dispatcher -Logger $logger
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

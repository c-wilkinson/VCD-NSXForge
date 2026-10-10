if ($RunUiTests -and [Environment]::UserInteractive -and $PSVersionTable.PSEdition -eq 'Desktop' -and
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    Invoke-TestCase -Name 'Bulk and template dialogs use accessible native controls without JSON fields' -Body {
        Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkBatchDialogs.psm1') -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkRuleTemplates.psm1') -ErrorAction Stop
        $bulk=New-NetworkBulkDialog -SelectedCount 2
        try {
            Assert-Equal 'NetworkBulkDialog' $bulk.Form.Name
            Assert-True ($null -ne $bulk.Form.Controls.Find('BulkAction',$true)[0])
            Assert-True ($null -ne $bulk.Form.Controls.Find('BulkStatus',$true)[0])
            Assert-True ($null -ne $bulk.Form.Controls.Find('BulkLogging',$true)[0])
            Assert-True ($null -ne $bulk.Form.AcceptButton) 'Bulk edit dialog missing keyboard Save'
            $bulk.Form.Show();[System.Windows.Forms.Application]::DoEvents()
            $bulk.Choices.Status.SelectedItem='Disabled'
            $bulk.SaveButton.PerformClick();[System.Windows.Forms.Application]::DoEvents()
            Assert-Equal 'Disabled' $bulk.Result.Value.Status
            Assert-Equal 'Keep' $bulk.Result.Value.Action
        }
        finally { $bulk.Form.Dispose() }
        $templates=@(Get-NetworkRuleTemplates -Path (Join-Path $ProjectRoot 'templates\firewall-rules.json'))
        $dialog=New-NetworkTemplateDialog -Templates $templates
        try {
            Assert-Equal 'NetworkTemplateDialog' $dialog.Form.Name
            Assert-True ($null -ne $dialog.Form.Controls.Find('RuleTemplatePicker',$true)[0])
            Assert-True ($null -ne $dialog.Form.Controls.Find('RuleTemplateName',$true)[0])
            $dialog.Form.Show();[System.Windows.Forms.Application]::DoEvents()
            $dialog.SaveButton.PerformClick();[System.Windows.Forms.Application]::DoEvents()
            Assert-True ($null -ne $dialog.Result.Value)
        }
        finally { $dialog.Form.Dispose() }
    }
    Invoke-TestCase -Name 'Editor constructs search filters batch actions RBAC and keyboard affordances' -Body {
        Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\NetworkEditorForm.psm1') -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -ErrorAction Stop
        Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Logging\Logging.psm1') -ErrorAction Stop
        $scratch=Join-Path ([IO.Path]::GetTempPath()) ('vcd-ui6-'+[guid]::NewGuid().ToString('n'))
        $logger=$null;$window=$null
        try {
            $logger=Start-AppLogger -ApplicationRoot $ProjectRoot -Directory $scratch -MaximumBytes 5000000 -RetentionDays 30
            $cfg=Read-AppConfiguration -ApplicationRoot $ProjectRoot
            $cfg.vcd.mode='Simulator';$cfg.vcd.apiUrl='http://127.0.0.1:8765'
            $window=New-NetworkEditorForm -Configuration $cfg -Logger $logger
            foreach ($kind in @('edgeFirewallRules','ipSets','manualIpReservations')) {
                foreach ($suffix in @('Search','ClearFilter','BulkRemoveButton')) {
                    Assert-Equal 1 @($window.Form.Controls.Find(($kind+$suffix),$true)).Count "Missing $kind$suffix"
                }
                $grid=$window.Form.Controls.Find(($kind+'List'),$true)[0]
                Assert-True $grid.MultiSelect 'Bulk actions require multi-select grids'
                Assert-True ($grid.AccessibleName.Length -gt 0) 'Resource grid should have an accessible name'
            }
            foreach ($name in @('SimulatorRoleLabel','edgeFirewallRulesBulkButton','edgeFirewallRulesTemplateButton','edgeFirewallRulesActionFilter','edgeFirewallRulesStatusFilter')) {
                Assert-Equal 1 @($window.Form.Controls.Find($name,$true)).Count "Missing $name"
            }
            Assert-True $window.Form.KeyPreview 'Ctrl+F navigation must reach the form'
            Assert-True (-not $window.Form.Controls.Find('ApplySimulatorButton',$true)[0].Enabled) 'No apply without a valid plan'
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
else {
    if (-not $RunUiTests) { Skip-TestCase -Name 'Bulk WinForms smoke tests' -Because 'Use -IncludeUi on an interactive Windows PowerShell 5.1 STA desktop.' }
}

# Native WinForms smoke checks for Issue #9 compatibility rendering.
Import-Module (Join-Path $ProjectRoot 'src\Presentation\WinForms\VcdCapabilityForm.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Capabilities\VcdCapabilityModel.psm1') -ErrorAction Stop
Invoke-TestCase -Name 'Compatibility form shows verdict and exact unsupported field paths without JSON editing' -Body {
    $report=New-VcdUnknownCapability -GatewayId 'urn:vcloud:gateway:test'
    $dialog=New-VcdCapabilityReportForm -Report $report
    try {
        Assert-True ($dialog.Verdict.Text -like '*Unknown*')
        Assert-True ($dialog.Verdict.Text -like '*DISABLED*')
        Assert-Equal 1 $dialog.Findings.Items.Count
        Assert-Equal 'gateway' $dialog.Findings.Items[0].SubItems[2].Text
        Assert-Equal 1 (@($dialog.Form.Controls.Find('CapabilityCloseButton',$true)).Count)
    } finally { $dialog.Form.Dispose() }
}

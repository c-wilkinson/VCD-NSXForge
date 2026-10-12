# Read-only native WinForms rendering of structured capability findings.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-VcdCapabilityReportForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)
    $form=[System.Windows.Forms.Form]::new()
    $form.Name='VcdCapabilityReportForm'
    $form.Text='VCD gateway compatibility (read only)'
    $form.ClientSize=[System.Drawing.Size]::new(920,560)
    $form.MinimumSize=[System.Drawing.Size]::new(720,480)
    $form.StartPosition='CenterParent'
    $form.Font=[System.Drawing.Font]::new('Segoe UI',10)
    $form.AutoScaleMode='Dpi'
    $layout=[System.Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock='Fill';$layout.Padding=[System.Windows.Forms.Padding]::new(12)
    $layout.ColumnCount=1;$layout.RowCount=4
    foreach ($height in @(46,78,0,48)) {
        $type=if($height -eq 0){[System.Windows.Forms.SizeType]::Percent}else{[System.Windows.Forms.SizeType]::Absolute}
        $value=if($height -eq 0){100}else{$height}
        [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new($type,$value))
    }
    $form.Controls.Add($layout)
    $heading=[System.Windows.Forms.Label]::new();$heading.Dock='Fill';$heading.Name='CapabilityVerdictLabel'
    $heading.Text=('Verdict: {0}   |   Live apply: DISABLED' -f $Report.Verdict)
    $heading.Font=[System.Drawing.Font]::new('Segoe UI Semibold',14)
    $heading.AccessibleName='Gateway compatibility verdict'
    $layout.Controls.Add($heading,0,0)
    $details=[System.Windows.Forms.Label]::new();$details.Dock='Fill';$details.AutoEllipsis=$true
    $details.Name='CapabilityEvidenceLabel'
    $details.Text=('Gateway: {0}' + [Environment]::NewLine + 'API: {1}; VCD: {2}; Mode: {3}; Backing: {4}; Catalogue: {5}') -f `
        $Report.GatewayId,$Report.ApiVersion,$Report.VcdRelease,$Report.GatewayMode,$Report.NetworkBacking,$Report.CatalogueId
    $details.AccessibleName='Tested API and gateway capability evidence'
    $layout.Controls.Add($details,0,1)
    $list=[System.Windows.Forms.ListView]::new();$list.Name='CapabilityFindingsList';$list.Dock='Fill'
    $list.View='Details';$list.FullRowSelect=$true;$list.GridLines=$true
    $list.HideSelection=$false;$list.MultiSelect=$false
    $list.AccessibleName='Compatibility limitations and field paths'
    [void]$list.Columns.Add('Status',110)
    [void]$list.Columns.Add('Code',175)
    [void]$list.Columns.Add('Field path',285)
    [void]$list.Columns.Add('Explanation',520)
    foreach ($finding in @($Report.Findings)) {
        $item=[System.Windows.Forms.ListViewItem]::new([string]$finding.Severity)
        [void]$item.SubItems.Add([string]$finding.Code)
        [void]$item.SubItems.Add([string]$finding.Path)
        [void]$item.SubItems.Add([string]$finding.Explanation)
        [void]$list.Items.Add($item)
    }
    $layout.Controls.Add($list,0,2)
    $close=[System.Windows.Forms.Button]::new();$close.Name='CapabilityCloseButton'
    $close.Text='Close';$close.Dock='Right';$close.Width=120;$close.DialogResult='OK'
    $layout.Controls.Add($close,0,3)
    $form.AcceptButton=$close;$form.CancelButton=$close
    return [pscustomobject]@{Form=$form;Verdict=$heading;Findings=$list}
}

Export-ModuleMember -Function New-VcdCapabilityReportForm

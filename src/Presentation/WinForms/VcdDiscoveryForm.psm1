# Engineer-friendly, read-only selection of verified, in-memory inventory objects.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-VcdDiscoverySelectionForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)
    if (-not $Inventory.Complete -or $Inventory.Visibility -cne 'PermissionScoped') {
        throw 'Incomplete VCD inventory cannot be used to select a target.'
    }
    $form = [System.Windows.Forms.Form]::new()
    $form.Name = 'VcdDiscoverySelectionForm'
    $form.Text = 'Browse VCD infrastructure (read only)'
    $form.ClientSize = [System.Drawing.Size]::new(795, 580)
    $form.MinimumSize = [System.Drawing.Size]::new(715, 525)
    $form.StartPosition = 'CenterParent'
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 10)
    $form.AutoScaleMode = 'Dpi'

    $layout = [System.Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'; $layout.Padding = [System.Windows.Forms.Padding]::new(14)
    $layout.ColumnCount = 1; $layout.RowCount = 9
    foreach ($height in @(38,25,48,25,48,25,48,0,62)) {
        $size = if ($height -eq 0) { [System.Windows.Forms.SizeType]::Percent } else { [System.Windows.Forms.SizeType]::Absolute }
        $value = if ($height -eq 0) { 100 } else { $height }
        [void]$layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new($size,$value))
    }
    $form.Controls.Add($layout)
    $heading = [System.Windows.Forms.Label]::new(); $heading.Dock='Fill'
    $heading.Text='Select an organisation, VDC, gateway and its networks. IDs are retained internally.'
    $layout.Controls.Add($heading,0,0)

    $choices = @{}
    foreach ($item in @(@{Key='Organisation';Row=1;Value=2},@{Key='VDC';Row=3;Value=4},@{Key='Edge Gateway';Row=5;Value=6})) {
        $label = [System.Windows.Forms.Label]::new(); $label.Text=$item.Key; $label.Dock='Fill'
        $layout.Controls.Add($label,0,$item.Row)
        $combo=[System.Windows.Forms.ComboBox]::new(); $combo.Name = ('Discovery'+$item.Key.Replace(' ','')+'Combo')
        $combo.Dock='Fill'; $combo.DropDownStyle='DropDownList'
        $combo.AccessibleName=('Select '+$item.Key)
        $layout.Controls.Add($combo,0,$item.Value)
        $choices[$item.Key]=$combo
    }
    $networkPanel = [System.Windows.Forms.TableLayoutPanel]::new(); $networkPanel.Dock='Fill'
    $networkPanel.RowCount=2; $networkPanel.ColumnCount=1
    [void]$networkPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,26))
    [void]$networkPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
    $networkLabel=[System.Windows.Forms.Label]::new(); $networkLabel.Text='Connected networks (check those to read)'; $networkLabel.Dock='Fill'
    $networks=[System.Windows.Forms.CheckedListBox]::new(); $networks.Name='DiscoveryNetworksList';$networks.Dock='Fill'
    $networks.CheckOnClick=$true;$networks.AccessibleName='Connected network choices'
    $networkPanel.Controls.Add($networkLabel,0,0); $networkPanel.Controls.Add($networks,0,1)
    $layout.Controls.Add($networkPanel,0,7)
    $footer=[System.Windows.Forms.TableLayoutPanel]::new();$footer.Dock='Fill';$footer.RowCount=2;$footer.ColumnCount=3
    [void]$footer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,50))
    [void]$footer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,50))
    [void]$footer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
    [void]$footer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,140))
    [void]$footer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,110))
    $notice=[System.Windows.Forms.Label]::new();$notice.Dock='Fill';$notice.AutoEllipsis=$true
    $notice.Text='Permission-scoped listing: absence does not prove an object does not exist.'
    $count=[System.Windows.Forms.Label]::new();$count.Dock='Fill';$count.AutoEllipsis=$true
    $cancel=[System.Windows.Forms.Button]::new();$cancel.Name='DiscoveryCancelButton';$cancel.Text='Cancel';$cancel.Dock='Fill';$cancel.DialogResult='Cancel'
    $accept=[System.Windows.Forms.Button]::new();$accept.Name='DiscoverySelectButton';$accept.Text='Use selection';$accept.Dock='Fill';$accept.Enabled=$false
    $footer.Controls.Add($notice,0,0);$footer.SetColumnSpan($notice,3)
    $footer.Controls.Add($count,0,1);$footer.Controls.Add($accept,1,1);$footer.Controls.Add($cancel,2,1)
    $layout.Controls.Add($footer,0,8)
    $form.CancelButton=$cancel
    $selected=[pscustomobject]@{GatewayId='';NetworkIds=@();OrgId='';VdcId=''}
    $optionSets=@{}
    $networkOptions=[System.Collections.Generic.List[object]]::new()

    $setItems = {
        param([string]$key, $values)
        $combo=$choices[$key]
        $optionSets[$key]=@($values)
        $combo.BeginUpdate()
        try {
            $combo.Items.Clear()
            foreach ($value in @($optionSets[$key])) { [void]$combo.Items.Add([string]$value.Label) }
            if ($combo.Items.Count -gt 0) { $combo.SelectedIndex=0 }
        } finally { $combo.EndUpdate() }
    }.GetNewClosure()
    $getSelected = {
        param([string]$key)
        $index=$choices[$key].SelectedIndex
        if ($index -lt 0 -or $null -eq $optionSets[$key]) { return $null }
        return $optionSets[$key][$index]
    }.GetNewClosure()

    $refreshNetworks = {
        $networks.Items.Clear()
        $networkOptions.Clear()
        $selectedGateway=& $getSelected 'Edge Gateway'
        if ($null -ne $selectedGateway) {
            foreach ($network in @($Inventory.Networks | Where-Object { $_.GatewayId -ceq $selectedGateway.Id })) {
                $networkOptions.Add($network)
                [void]$networks.Items.Add([string]$network.Label, $true)
            }
        }
        $count.Text=('Visible: {0} organisations, {1} VDCs, {2} gateways; {3} attached networks' -f @($Inventory.Organisations).Count,@($Inventory.Vdcs).Count,@($Inventory.Gateways).Count,$networks.Items.Count)
        $accept.Enabled=($null -ne $selectedGateway)
    }.GetNewClosure()
    $refreshGateways = {
        $org=& $getSelected 'Organisation'
        $vdc=& $getSelected 'VDC'
        $found=@()
        if ($null -ne $org -and $null -ne $vdc) {
            $found=@($Inventory.Gateways | Where-Object { $_.OrgId -ceq $org.Id -and $_.VdcId -ceq $vdc.Id })
        }
        & $setItems 'Edge Gateway' $found
        & $refreshNetworks
    }.GetNewClosure()
    $refreshVdcs = {
        $org=& $getSelected 'Organisation'
        $found=@()
        if ($null -ne $org) {
            $found=@($Inventory.Vdcs | Where-Object { $_.OrgId -ceq $org.Id })
            if (@($Inventory.Gateways | Where-Object { $_.OrgId -ceq $org.Id -and -not $_.VdcId }).Count -gt 0) {
                $found+= [pscustomobject]@{Id='';Name='Shared or unassigned';Label='Shared / group-owned gateways (VDC not asserted)'}
            }
        }
        & $setItems 'VDC' $found
        & $refreshGateways
    }.GetNewClosure()
    $choices['Organisation'].Add_SelectedIndexChanged({ & $refreshVdcs }.GetNewClosure())
    $choices['VDC'].Add_SelectedIndexChanged({ & $refreshGateways }.GetNewClosure())
    $choices['Edge Gateway'].Add_SelectedIndexChanged({ & $refreshNetworks }.GetNewClosure())
    $accept.Add_Click({
        $org=& $getSelected 'Organisation'
        $vdc=& $getSelected 'VDC'
        $gateway=& $getSelected 'Edge Gateway'
        if ($null -eq $org -or $null -eq $vdc -or $null -eq $gateway) { return }
        if ($gateway.OrgId -cne $org.Id -or $gateway.VdcId -cne $vdc.Id) { return }
        $selected.OrgId=$org.Id;$selected.VdcId=$vdc.Id;$selected.GatewayId=$gateway.Id
        $selected.NetworkIds=@(foreach ($index in $networks.CheckedIndices) { $networkOptions[[int]$index].Id })
        $form.DialogResult='OK';$form.Close()
    }.GetNewClosure())
    & $setItems 'Organisation' $Inventory.Organisations
    & $refreshVdcs
    return [pscustomobject]@{Form=$form; Selection=$selected}
}

Export-ModuleMember -Function New-VcdDiscoverySelectionForm

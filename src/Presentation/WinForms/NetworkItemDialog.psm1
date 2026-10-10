# Human-friendly network resource dialogs. JSON is an internal persistence detail.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\..\Application\Editing\NetworkEditorInputs.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop

function Add-NetworkDialogField {
    param([System.Windows.Forms.TableLayoutPanel]$Layout,[string]$Caption,[System.Windows.Forms.Control]$Control,[string]$ControlName)
    $row=$Layout.RowCount
    $Layout.RowCount++
    $Layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $label=[System.Windows.Forms.Label]::new()
    $label.Text=$Caption;$label.AutoSize=$true;$label.Margin=[System.Windows.Forms.Padding]::new(4,10,4,5)
    $Layout.Controls.Add($label,0,$row)
    $Control.Name=$ControlName;$Control.Margin=[System.Windows.Forms.Padding]::new(4,6,8,6)
    $Control.Dock='Top'
    $Layout.Controls.Add($Control,1,$row)
    return $Control
}

function New-NetworkDialogText {
    param([string]$Text='', [switch]$Multiline)
    $field=[System.Windows.Forms.TextBox]::new()
    $field.Text=$Text
    if ($Multiline) { $field.Multiline=$true;$field.ScrollBars='Vertical';$field.Height=100 }
    else { $field.Height=29 }
    return $field
}

function New-NetworkDialogLayout {
    $layout=[System.Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock='Fill';$layout.AutoScroll=$true;$layout.AutoSize=$false
    $layout.ColumnCount=2;$layout.Padding=[System.Windows.Forms.Padding]::new(12)
    $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,180)) | Out-Null
    $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
    return $layout
}

# Invoked only on the owning STA WinForms UI thread. Do not use worker APIs here.
function Invoke-NetworkItemDialogSave {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $feedback=$Context.ValidationLabel
    if (-not ($feedback -is [System.Windows.Forms.Label])) {
        throw 'The firewall dialog validation control was not initialised correctly.'
    }
    try {
        $feedback.Text=''
        $feedback.AccessibleDescription=''
        $ui=$Context.Controls
        $kind=[string]$Context.ResourceKind
        $fields=@{
            Key=[string]$ui.Key.Text
            Description=[string]$ui.Description.Text
        }
        if ($kind -eq 'ipSets') {
            $fields.Name=[string]$ui.Name.Text
            $fields.Addresses=[string]$ui.Addresses.Text
        }
        elseif ($kind -eq 'manualIpReservations') {
            $fields.NetworkId=[string]$ui.Network.Tag
            $fields.Address=[string]$ui.Address.Text
        }
        else {
            $fields.Name=[string]$ui.Name.Text
            $fields.Action=[string]$ui.Action.SelectedItem
            $fields.Enabled=[bool]$ui.Enabled.Checked
            $fields.Logging=[bool]$ui.Logging.Checked
            $fields.Order=if ($Context.Create) {
                @($Context.Documents.edgeFirewallRules.items).Count
            } else { [int]$Context.Original.order }
            $fields.Sources=@()
            $fields.Destinations=@()
            $fields.Services=@()
            foreach ($index in @($ui.Sources.CheckedIndices)) {
                $fields.Sources+= $Context.IpSetKeys[[int]$index]
            }
            foreach ($index in @($ui.Destinations.CheckedIndices)) {
                $fields.Destinations+= $Context.IpSetKeys[[int]$index]
            }
            [void]$ui.Services.EndEdit()
            for ($i=0; $i -lt $ui.Services.Rows.Count; $i++) {
                $row=$ui.Services.Rows[$i]
                if ($row.IsNewRow) { continue }
                $fields.Services+= @{
                    Protocol=[string]$row.Cells['Protocol'].Value
                    Ports=[string]$row.Cells['Ports'].Value
                }
            }
        }

        $item=& $Context.BuildCommand -ResourceKind $kind -Fields $fields
        if (-not $Context.Create -and $item.key -cne $Context.Original.key) {
            throw 'The stable identifier cannot be changed on an existing resource.'
        }
        # Validate the whole copy of the network without modifying the draft.
        $null=& $Context.SetCommand -Documents $Context.Documents -ResourceKind $kind -Item $item -Create:([bool]$Context.Create)
        $Context.Result.Value=$item
        $Context.Form.DialogResult=[System.Windows.Forms.DialogResult]::OK
        $Context.Form.Close()
    }
    catch {
        # Keep the form open and retain edits. Error details are available to
        # tests and accessibility tooling without disrupting the UI thread.
        $Context.Form.DialogResult=[System.Windows.Forms.DialogResult]::None
        $feedback.Text=[string]$_.Exception.Message
        $feedback.AccessibleDescription=[string]$_.Exception.ToString()
    }
}

function New-NetworkItemDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('edgeFirewallRules','ipSets','manualIpReservations')][string]$ResourceKind,
        [Parameter(Mandatory)]$Documents,
        $Original = $null,
        [string]$NetworkId = '',
        [string]$NetworkLabel = 'Current gateway network'
    )
    $create = ($null -eq $Original)
    $title = switch ($ResourceKind) {
        'edgeFirewallRules' {'Firewall rule'}
        'ipSets' {'IP Set'}
        'manualIpReservations' {'IP reservation'}
    }
    $form=[System.Windows.Forms.Form]::new()
    $form.Name='NetworkItemDialog';$form.Text=$(if ($create) { 'Create '+$title } else { 'Edit '+$title })
    $form.ClientSize=[System.Drawing.Size]::new(770,615)
    $form.MinimumSize=[System.Drawing.Size]::new(700,560)
    $form.StartPosition='CenterParent';$form.Font=[System.Drawing.Font]::new('Segoe UI',9)
    $form.AutoScaleMode=[System.Windows.Forms.AutoScaleMode]::Font
    $result=[pscustomobject]@{Value=$null}

    # Explicit two-row container: tabs cannot cover the fixed footer at any DPI.
    # Previously the tab control was Dock=Fill and the footer had manually
    # positioned children. On scaled/small displays the actions could disappear.
    $root=[System.Windows.Forms.TableLayoutPanel]::new()
    $root.Name='NetworkItemRootLayout';$root.Dock='Fill'
    $root.ColumnCount=1;$root.RowCount=2;$root.Padding=[System.Windows.Forms.Padding]::new(0)
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
    $root.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,120)) | Out-Null
    $form.Controls.Add($root)

    $tabs=[System.Windows.Forms.TabControl]::new();$tabs.Name='NetworkItemTabs';$tabs.Dock='Fill'
    $root.Controls.Add($tabs,0,0)

    $footer=[System.Windows.Forms.TableLayoutPanel]::new()
    $footer.Name='NetworkItemFooter';$footer.Dock='Fill'
    $footer.Padding=[System.Windows.Forms.Padding]::new(12,3,12,6)
    $footer.ColumnCount=1;$footer.RowCount=3
    $footer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,35)) | Out-Null
    $footer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,24)) | Out-Null
    $footer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
    $root.Controls.Add($footer,0,1)

    # Never use $error: it is PowerShell's case-insensitive automatic $Error history.
    # The click handler runs in a GetNewClosure() scope, where $Error points to
    # ErrorRecords, not our Label; attempted .Text writes then throw.
    $validationLabel=[System.Windows.Forms.Label]::new()
    $validationLabel.Name='NetworkItemValidation'
    $validationLabel.ForeColor=[System.Drawing.Color]::DarkRed
    $validationLabel.TextAlign='MiddleLeft'
    $validationLabel.AutoEllipsis=$true
    $validationLabel.Dock='Fill'
    $footer.Controls.Add($validationLabel,0,0)

    $hint=[System.Windows.Forms.Label]::new()
    $hint.Name='NetworkItemSaveHint'
    $hint.Text='Saves to the local draft only. Generate a plan to review changes before applying.'
    $hint.ForeColor=[System.Drawing.SystemColors]::GrayText
    $hint.TextAlign='MiddleLeft';$hint.Dock='Fill';$hint.AutoEllipsis=$true
    $footer.Controls.Add($hint,0,1)

    $actions=[System.Windows.Forms.FlowLayoutPanel]::new()
    $actions.Name='NetworkItemFooterActions';$actions.Dock='Fill'
    $actions.FlowDirection=[System.Windows.Forms.FlowDirection]::RightToLeft
    $actions.WrapContents=$false;$actions.AutoScroll=$false
    $actions.Padding=[System.Windows.Forms.Padding]::new(0,3,0,0)
    $footer.Controls.Add($actions,0,2)

    $cancel=[System.Windows.Forms.Button]::new()
    $cancel.Name='CancelNetworkItemButton';$cancel.Text='Cancel'
    $cancel.Size=[System.Drawing.Size]::new(110,34)
    $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $save=[System.Windows.Forms.Button]::new()
    $save.Name='SaveNetworkItemButton'
    $save.Text=$(if ($create) { 'Add to draft' } else { 'Save changes' })
    $save.Size=[System.Drawing.Size]::new(145,34)
    $save.DialogResult=[System.Windows.Forms.DialogResult]::None
    $actions.Controls.Add($cancel)
    $actions.Controls.Add($save)
    $form.AcceptButton=$save
    $form.CancelButton=$cancel

    $general=[System.Windows.Forms.TabPage]::new();$general.Text='Details';$general.Name='NetworkItemDetailsTab'
    $generalLayout=New-NetworkDialogLayout
    $general.Controls.Add($generalLayout);[void]$tabs.TabPages.Add($general)

    $name=$null;$key=$null;$description=$null;$address=$null;$addresses=$null;$network=$null
    $action=$null;$enabled=$null;$logging=$null;$sources=$null;$destinations=$null;$services=$null
    $ipSetKeys=@()

    if ($ResourceKind -ne 'manualIpReservations') {
        $name=Add-NetworkDialogField $generalLayout 'Name *' (New-NetworkDialogText -Text $(if ($create) {''} else {[string]$Original.name})) 'NetworkItemName'
    }
    $key=Add-NetworkDialogField $generalLayout 'Internal ID (optional)' (New-NetworkDialogText -Text $(if ($create) {''} else {[string]$Original.key})) 'NetworkItemKey'
    if (-not $create) { $key.ReadOnly=$true;$key.BackColor=[System.Drawing.SystemColors]::Control }
    $existingDescription=''
    if (-not $create -and @($Original.PSObject.Properties.Name) -contains 'description') { $existingDescription=[string]$Original.description }
    $description=Add-NetworkDialogField $generalLayout 'Description' (New-NetworkDialogText -Text $existingDescription -Multiline) 'NetworkItemDescription'

    if ($ResourceKind -eq 'ipSets') {
        $addresses=Add-NetworkDialogField $generalLayout 'IP addresses / CIDRs *' (New-NetworkDialogText -Text $(if ($create) {''} else { @($Original.addresses) -join [Environment]::NewLine }) -Multiline) 'NetworkItemAddresses'
        $hint=[System.Windows.Forms.Label]::new();$hint.Text='Enter one address or CIDR per line. Commas are also accepted.';$hint.AutoSize=$true
        $generalLayout.RowCount++
        $generalLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)) | Out-Null
        $generalLayout.Controls.Add($hint,1,$generalLayout.RowCount-1)
    }
    elseif ($ResourceKind -eq 'manualIpReservations') {
        $network=Add-NetworkDialogField $generalLayout 'Network' (New-NetworkDialogText -Text $NetworkLabel) 'NetworkItemNetworkId'
        $network.ReadOnly=$true
        $network.Tag=$(if ($create) { $NetworkId } else { [string]$Original.networkId })
        $address=Add-NetworkDialogField $generalLayout 'Reserved IP address *' (New-NetworkDialogText -Text $(if ($create) {''} else {[string]$Original.address})) 'NetworkItemAddress'
    }
    else {
        $action=[System.Windows.Forms.ComboBox]::new();$action.DropDownStyle='DropDownList';$action.Items.AddRange([object[]]@('ALLOW','DROP','REJECT'))
        $null=Add-NetworkDialogField $generalLayout 'Action' $action 'NetworkItemAction'
        $chosen=if ($create) {'ALLOW'} else {[string]$Original.action};$action.SelectedItem=$chosen
        $enabled=[System.Windows.Forms.CheckBox]::new();$enabled.Text='Rule enabled';$enabled.Checked=($create -or [bool]$Original.enabled)
        $null=Add-NetworkDialogField $generalLayout 'Status' $enabled 'NetworkItemEnabled'
        $logging=[System.Windows.Forms.CheckBox]::new();$logging.Text='Log matching traffic';$logging.Checked=($create -or [bool]$Original.logging)
        $null=Add-NetworkDialogField $generalLayout 'Logging' $logging 'NetworkItemLogging'
        $orderLabel=[System.Windows.Forms.Label]::new();$orderLabel.AutoSize=$true
        $orderLabel.Text=if ($create) {'New rule is appended to the bottom; use Move Up / Down to reorder.'} else {'Rule priority is changed with Move Up / Down in the firewall list.'}
        $generalLayout.RowCount++
        $generalLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::AutoSize)) | Out-Null
        $generalLayout.Controls.Add($orderLabel,1,$generalLayout.RowCount-1)

        $addressTab=[System.Windows.Forms.TabPage]::new();$addressTab.Text='Sources and destinations'
        $addressLayout=[System.Windows.Forms.TableLayoutPanel]::new();$addressLayout.Dock='Fill';$addressLayout.ColumnCount=2
        $addressLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,50)) | Out-Null
        $addressLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,50)) | Out-Null
        $sourceBox=[System.Windows.Forms.GroupBox]::new();$sourceBox.Text='Source IP Sets (none = Any)';$sourceBox.Dock='Fill';$sourceBox.Padding=[System.Windows.Forms.Padding]::new(12)
        $destinationBox=[System.Windows.Forms.GroupBox]::new();$destinationBox.Text='Destination IP Sets (none = Any)';$destinationBox.Dock='Fill';$destinationBox.Padding=[System.Windows.Forms.Padding]::new(12)
        $sources=[System.Windows.Forms.CheckedListBox]::new();$sources.Name='NetworkItemSources';$sources.Dock='Fill';$sources.CheckOnClick=$true
        $destinations=[System.Windows.Forms.CheckedListBox]::new();$destinations.Name='NetworkItemDestinations';$destinations.Dock='Fill';$destinations.CheckOnClick=$true
        $ipSetKeys=@()
        foreach ($set in @($Documents.ipSets.items | Sort-Object name)) {
            $ipSetKeys+= [string]$set.key
            $si=$sources.Items.Add(('{0} ({1})' -f $set.name,$set.key))
            $di=$destinations.Items.Add(('{0} ({1})' -f $set.name,$set.key))
            if (-not $create) {
                if (@($Original.sourceIpSets) -ccontains $set.key) { $sources.SetItemChecked($si,$true) }
                if (@($Original.destinationIpSets) -ccontains $set.key) { $destinations.SetItemChecked($di,$true) }
            }
        }
        $sourceBox.Controls.Add($sources);$destinationBox.Controls.Add($destinations)
        $addressLayout.Controls.Add($sourceBox,0,0);$addressLayout.Controls.Add($destinationBox,1,0)
        $addressTab.Controls.Add($addressLayout);[void]$tabs.TabPages.Add($addressTab)

        $serviceTab=[System.Windows.Forms.TabPage]::new();$serviceTab.Text='Services and ports'
        $serviceLayout=[System.Windows.Forms.TableLayoutPanel]::new();$serviceLayout.Dock='Fill';$serviceLayout.RowCount=3
        $serviceLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,45)) | Out-Null
        $serviceLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
        $serviceLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,40)) | Out-Null
        $tools=[System.Windows.Forms.FlowLayoutPanel]::new();$tools.Dock='Fill'
        $addService=[System.Windows.Forms.Button]::new();$addService.Text='Add service';$addService.Name='NetworkItemAddService';$addService.Width=110
        $removeService=[System.Windows.Forms.Button]::new();$removeService.Text='Remove selected';$removeService.Name='NetworkItemRemoveService';$removeService.Width=130
        $tools.Controls.AddRange([System.Windows.Forms.Control[]]@($addService,$removeService))
        $services=[System.Windows.Forms.DataGridView]::new();$services.Dock='Fill';$services.Name='NetworkItemServices'
        $services.AllowUserToAddRows=$false;$services.AllowUserToDeleteRows=$false;$services.AutoSizeColumnsMode='Fill'
        $services.SelectionMode='FullRowSelect';$services.MultiSelect=$false;$services.RowHeadersVisible=$false
        $protocolColumn=[System.Windows.Forms.DataGridViewComboBoxColumn]::new();$protocolColumn.Name='Protocol';$protocolColumn.HeaderText='Protocol';$protocolColumn.Items.AddRange([object[]]@('TCP','UDP','ICMP','ANY'))
        $portColumn=[System.Windows.Forms.DataGridViewTextBoxColumn]::new();$portColumn.Name='Ports';$portColumn.HeaderText='Destination ports (e.g. 443, 8000-8010)'
        $services.Columns.Add($protocolColumn) | Out-Null;$services.Columns.Add($portColumn) | Out-Null
        if (-not $create) {
            foreach ($s in @($Original.services)) { [void]$services.Rows.Add([string]$s.protocol,(@($s.ports) -join ', ')) }
        }
        $addService.Add_Click({ [void]$services.Rows.Add('TCP','443') }.GetNewClosure())
        $removeService.Add_Click({ if ($null -ne $services.CurrentRow) { $services.Rows.Remove($services.CurrentRow) } }.GetNewClosure())
        $serviceHelp=[System.Windows.Forms.Label]::new();$serviceHelp.Text='No service rows = Any. ICMP/ANY must have empty ports. Multiple rows are allowed.';$serviceHelp.AutoSize=$true
        $serviceLayout.Controls.Add($tools,0,0);$serviceLayout.Controls.Add($services,0,1);$serviceLayout.Controls.Add($serviceHelp,0,2)
        $serviceTab.Controls.Add($serviceLayout);[void]$tabs.TabPages.Add($serviceTab)
    }

    # Event handlers have their own PowerShell 5.1 scope. Capture ONE explicit
    # state object rather than relying on a collection of local UI variables.
    # The WinForms controls are never passed to a worker runspace.
    $saveContext=[pscustomobject]@{
        Form=$form
        Result=$result
        ValidationLabel=$validationLabel
        Documents=$Documents
        ResourceKind=$ResourceKind
        Original=$Original
        Create=$create
        IpSetKeys=[string[]]@($ipSetKeys)
        BuildCommand=(Get-Command ConvertTo-NetworkEditorItem -ErrorAction Stop)
        SetCommand=(Get-Command Set-NetworkDraftItem -ErrorAction Stop)
        Controls=[pscustomobject]@{
            Name=$name;Key=$key;Description=$description
            Address=$address;Addresses=$addresses;Network=$network
            Action=$action;Enabled=$enabled;Logging=$logging
            Sources=$sources;Destinations=$destinations;Services=$services
        }
        SaveCommand=(Get-Command Invoke-NetworkItemDialogSave -ErrorAction Stop)
    }
    $save.Add_Click({ & $saveContext.SaveCommand -Context $saveContext }.GetNewClosure())
    # Expose the actual containers as well as named UI controls for layout
    # regression tests; recursive Controls.Find can be unreliable for containers
    # on some Windows Forms versions, although child buttons are discoverable.
    return [pscustomobject]@{
        Form=$form;Result=$result
        Root=$root;Footer=$footer
        SaveButton=$save;CancelButton=$cancel;ValidationLabel=$validationLabel
    }
}

function Show-NetworkItemDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('edgeFirewallRules','ipSets','manualIpReservations')][string]$ResourceKind,
        [Parameter(Mandatory)]$Documents,
        $Original=$null,
        [string]$NetworkId='',
        [string]$NetworkLabel='Current gateway network',
        [System.Windows.Forms.IWin32Window]$Owner=$null
    )
    $dialog=New-NetworkItemDialog -ResourceKind $ResourceKind -Documents $Documents -Original $Original -NetworkId $NetworkId -NetworkLabel $NetworkLabel
    try {
        $outcome=if ($null -eq $Owner) { $dialog.Form.ShowDialog() } else { $dialog.Form.ShowDialog($Owner) }
        if ($outcome -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.Result.Value }
        return $null
    }
    finally { $dialog.Form.Dispose() }
}

Export-ModuleMember -Function New-NetworkItemDialog, Show-NetworkItemDialog

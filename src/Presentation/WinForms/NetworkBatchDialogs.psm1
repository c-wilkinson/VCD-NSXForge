# Engineer-oriented dialogs for batch rule properties and starter templates.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-NetworkBulkDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$SelectedCount)
    if ($SelectedCount -lt 1) { throw 'Select at least one rule.' }
    $form=[System.Windows.Forms.Form]::new();$form.Name='NetworkBulkDialog'
    $form.Text="Bulk update $SelectedCount selected firewall rules"
    $form.ClientSize=[System.Drawing.Size]::new(520,315);$form.MinimumSize=[System.Drawing.Size]::new(500,350)
    $form.StartPosition='CenterParent';$form.Font=[System.Drawing.Font]::new('Segoe UI',10)
    $form.AutoScaleMode='Font'
    $layout=[System.Windows.Forms.TableLayoutPanel]::new();$layout.Dock='Fill';$layout.Padding=[System.Windows.Forms.Padding]::new(14)
    $layout.RowCount=5;$layout.ColumnCount=2
    $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,190)) | Out-Null
    $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
    for ($i=0;$i -lt 4;$i++) { $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,53)) | Out-Null }
    $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
    $choices=@{}
    foreach ($detail in @(@('Action','Rule action',@('Keep','ALLOW','DROP','REJECT')),
                         @('Status','Rule status',@('Keep','Enabled','Disabled')),
                         @('Logging','Traffic logging',@('Keep','On','Off')))) {
        $row=switch ($detail[0]) { 'Action' {0};'Status' {1};'Logging' {2} };$label=[System.Windows.Forms.Label]::new()
        $label.Text=$detail[1];$label.Dock='Fill';$label.TextAlign='MiddleLeft'
        $combo=[System.Windows.Forms.ComboBox]::new();$combo.Name="Bulk$($detail[0])";$combo.AccessibleName=$detail[1]
        $combo.DropDownStyle='DropDownList';$combo.Dock='Fill';$combo.Margin=[System.Windows.Forms.Padding]::new(4,9,4,8)
        foreach ($item in $detail[2]) { [void]$combo.Items.Add($item) };$combo.SelectedIndex=0
        $layout.Controls.Add($label,0,$row);$layout.Controls.Add($combo,1,$row);$choices[$detail[0]]=$combo
    }
    $note=[System.Windows.Forms.Label]::new();$note.Text='Keep leaves the existing value unchanged. All changes remain in the draft.'
    $note.Dock='Fill';$note.AutoSize=$false;$note.AccessibleName='Bulk operation guidance';$layout.Controls.Add($note,0,3);$layout.SetColumnSpan($note,2)
    $footer=[System.Windows.Forms.FlowLayoutPanel]::new();$footer.Dock='Fill';$footer.FlowDirection='RightToLeft'
    $save=[System.Windows.Forms.Button]::new();$save.Name='BulkSaveButton';$save.Text='Apply to draft';$save.Width=134;$save.Height=33
    $cancel=[System.Windows.Forms.Button]::new();$cancel.Name='BulkCancelButton';$cancel.Text='Cancel';$cancel.Width=100;$cancel.Height=33
    $feedback=[System.Windows.Forms.Label]::new();$feedback.Name='BulkValidation';$feedback.AutoSize=$true;$feedback.ForeColor=[System.Drawing.SystemColors]::ControlText
    $footer.Controls.AddRange([System.Windows.Forms.Control[]]@($cancel,$save,$feedback))
    $layout.Controls.Add($footer,0,4);$layout.SetColumnSpan($footer,2);$form.Controls.Add($layout)
    $result=[pscustomobject]@{Value=$null}
    $ctx=[pscustomobject]@{Form=$form;Choices=$choices;Result=$result;Feedback=$feedback}
    $save.Add_Click({
        $values=@{Action=[string]$ctx.Choices.Action.SelectedItem;Status=[string]$ctx.Choices.Status.SelectedItem;Logging=[string]$ctx.Choices.Logging.SelectedItem}
        if ($values.Action -eq 'Keep' -and $values.Status -eq 'Keep' -and $values.Logging -eq 'Keep') { $ctx.Feedback.Text='Choose at least one property to change.';return }
        $ctx.Result.Value=$values;$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::OK;$ctx.Form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$ctx.Form.Close()}.GetNewClosure())
    $form.AcceptButton=$save;$form.CancelButton=$cancel
    return [pscustomobject]@{Form=$form;Result=$result;SaveButton=$save;CancelButton=$cancel;Choices=$choices}
}

function Show-NetworkBulkDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$SelectedCount,[System.Windows.Forms.IWin32Window]$Owner)
    $dialog=New-NetworkBulkDialog -SelectedCount $SelectedCount
    try { if ($null -ne $Owner) { [void]$dialog.Form.ShowDialog($Owner) } else { [void]$dialog.Form.ShowDialog() };return $dialog.Result.Value }
    finally { $dialog.Form.Dispose() }
}

function New-NetworkTemplateDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Templates)
    if ($Templates.Count -eq 0) { throw 'No templates available.' }
    $form=[System.Windows.Forms.Form]::new();$form.Name='NetworkTemplateDialog';$form.Text='Create rule from template'
    $form.ClientSize=[System.Drawing.Size]::new(500,235);$form.MinimumSize=[System.Drawing.Size]::new(480,260)
    $form.StartPosition='CenterParent';$form.Font=[System.Drawing.Font]::new('Segoe UI',10)
    $templateLabel=[System.Windows.Forms.Label]::new();$templateLabel.Text='Rule template';$templateLabel.SetBounds(20,18,160,24)
    $picker=[System.Windows.Forms.ComboBox]::new();$picker.Name='RuleTemplatePicker';$picker.AccessibleName='Rule template';$picker.DropDownStyle='DropDownList';$picker.SetBounds(20,46,445,30)
    foreach ($t in $Templates) { [void]$picker.Items.Add([string]$t.name) };$picker.SelectedIndex=0
    $nameLabel=[System.Windows.Forms.Label]::new();$nameLabel.Text='New rule name';$nameLabel.SetBounds(20,88,200,24)
    $name=[System.Windows.Forms.TextBox]::new();$name.Name='RuleTemplateName';$name.AccessibleName='New rule name';$name.SetBounds(20,114,445,30)
    $name.Text=[string]$Templates[0].name
    $picker.Add_SelectedIndexChanged({$name.Text=[string]$Templates[$picker.SelectedIndex].name}.GetNewClosure())
    $save=[System.Windows.Forms.Button]::new();$save.Name='TemplateCreateButton';$save.Text='Review rule';$save.SetBounds(300,175,160,34)
    $cancel=[System.Windows.Forms.Button]::new();$cancel.Name='TemplateCancelButton';$cancel.Text='Cancel';$cancel.SetBounds(190,175,100,34)
    $form.Controls.AddRange([System.Windows.Forms.Control[]]@($templateLabel,$picker,$nameLabel,$name,$save,$cancel))
    $result=[pscustomobject]@{Value=$null}
    $ctx=[pscustomobject]@{Form=$form;Picker=$picker;Name=$name;Templates=$Templates;Result=$result}
    $save.Add_Click({
        if ([string]::IsNullOrWhiteSpace($ctx.Name.Text)) { [System.Windows.Forms.MessageBox]::Show('Enter a rule name.','Validation') | Out-Null;return }
        $ctx.Result.Value=[pscustomobject]@{Template=$ctx.Templates[$ctx.Picker.SelectedIndex];Name=$ctx.Name.Text.Trim()}
        $ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::OK;$ctx.Form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$ctx.Form.Close()}.GetNewClosure())
    $form.AcceptButton=$save;$form.CancelButton=$cancel
    return [pscustomobject]@{Form=$form;Result=$result;SaveButton=$save;CancelButton=$cancel}
}

function Show-NetworkTemplateDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Templates,[System.Windows.Forms.IWin32Window]$Owner)
    $dialog=New-NetworkTemplateDialog -Templates $Templates
    try { if ($null -ne $Owner) { [void]$dialog.Form.ShowDialog($Owner) } else { [void]$dialog.Form.ShowDialog() };return $dialog.Result.Value }
    finally { $dialog.Form.Dispose() }
}


function New-NetworkTemplateSaveDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DefaultName)
    $form=[System.Windows.Forms.Form]::new();$form.Name='NetworkTemplateSaveDialog';$form.Text='Save rule as reusable template'
    $form.ClientSize=[System.Drawing.Size]::new(460,175);$form.MinimumSize=[System.Drawing.Size]::new(440,210)
    $form.StartPosition='CenterParent';$form.Font=[System.Drawing.Font]::new('Segoe UI',10)
    $label=[System.Windows.Forms.Label]::new();$label.Text='Template name';$label.SetBounds(16,15,240,22)
    $name=[System.Windows.Forms.TextBox]::new();$name.Name='SaveTemplateName';$name.AccessibleName='Template name';$name.Text=$DefaultName;$name.SetBounds(16,44,420,29)
    $note=[System.Windows.Forms.Label]::new();$note.Text='Source and destination IP Sets are not saved in templates.';$note.SetBounds(16,82,425,26)
    $cancel=[System.Windows.Forms.Button]::new();$cancel.Name='SaveTemplateCancel';$cancel.Text='Cancel';$cancel.SetBounds(190,125,95,31)
    $save=[System.Windows.Forms.Button]::new();$save.Name='SaveTemplateAccept';$save.Text='Save template';$save.SetBounds(300,125,136,31)
    $form.Controls.AddRange([System.Windows.Forms.Control[]]@($label,$name,$note,$cancel,$save))
    $result=[pscustomobject]@{Name=''}
    $ctx=[pscustomobject]@{Form=$form;Name=$name;Result=$result}
    $save.Add_Click({
        if ($ctx.Name.Text.Trim().Length -lt 3) { [System.Windows.Forms.MessageBox]::Show('Enter at least three characters.','Template name') | Out-Null;return }
        $ctx.Result.Name=$ctx.Name.Text.Trim();$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::OK;$ctx.Form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$ctx.Form.Close()}.GetNewClosure())
    $form.AcceptButton=$save;$form.CancelButton=$cancel
    return [pscustomobject]@{Form=$form;Result=$result;SaveButton=$save}
}

function Show-NetworkTemplateSaveDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DefaultName,[System.Windows.Forms.IWin32Window]$Owner)
    $dialog=New-NetworkTemplateSaveDialog -DefaultName $DefaultName
    try {
        $status=if ($null -ne $Owner) { $dialog.Form.ShowDialog($Owner) } else { $dialog.Form.ShowDialog() }
        if ($status -eq [System.Windows.Forms.DialogResult]::OK) { return [string]$dialog.Result.Name }
        return $null
    }
    finally { $dialog.Form.Dispose() }
}

function New-NetworkBulkDescriptionDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$SelectedCount)
    if ($SelectedCount -lt 1) { throw 'Select resources first.' }
    $form=[System.Windows.Forms.Form]::new();$form.Name='NetworkBulkDescriptionDialog';$form.Text="Edit description on $SelectedCount resources"
    $form.ClientSize=[System.Drawing.Size]::new(490,235);$form.StartPosition='CenterParent';$form.Font=[System.Drawing.Font]::new('Segoe UI',10)
    $label=[System.Windows.Forms.Label]::new();$label.Text='New description for all selected resources';$label.SetBounds(16,16,450,28)
    $field=[System.Windows.Forms.TextBox]::new();$field.Name='BulkDescription';$field.AccessibleName='New description for selected resources';$field.Multiline=$true;$field.SetBounds(16,49,454,105)
    $cancel=[System.Windows.Forms.Button]::new();$cancel.Name='BulkDescriptionCancel';$cancel.Text='Cancel';$cancel.SetBounds(220,183,100,33)
    $save=[System.Windows.Forms.Button]::new();$save.Name='BulkDescriptionSave';$save.Text='Apply to draft';$save.SetBounds(332,183,137,33)
    $form.Controls.AddRange([System.Windows.Forms.Control[]]@($label,$field,$cancel,$save))
    $result=[pscustomobject]@{Value=$null}
    $ctx=[pscustomobject]@{Form=$form;Field=$field;Result=$result}
    $save.Add_Click({$ctx.Result.Value=[string]$ctx.Field.Text;$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::OK;$ctx.Form.Close()}.GetNewClosure())
    $cancel.Add_Click({$ctx.Form.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$ctx.Form.Close()}.GetNewClosure())
    $form.AcceptButton=$save;$form.CancelButton=$cancel
    return [pscustomobject]@{Form=$form;Result=$result;SaveButton=$save}
}

function Show-NetworkBulkDescriptionDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$SelectedCount,[System.Windows.Forms.IWin32Window]$Owner)
    $dialog=New-NetworkBulkDescriptionDialog -SelectedCount $SelectedCount
    try {
        $status=if ($null -ne $Owner) { $dialog.Form.ShowDialog($Owner) } else { $dialog.Form.ShowDialog() }
        if ($status -eq [System.Windows.Forms.DialogResult]::OK) { return [pscustomobject]@{Description=$dialog.Result.Value} }
        return $null
    }
    finally { $dialog.Form.Dispose() }
}

Export-ModuleMember -Function New-NetworkBulkDialog, Show-NetworkBulkDialog, New-NetworkTemplateDialog, Show-NetworkTemplateDialog, New-NetworkTemplateSaveDialog, Show-NetworkTemplateSaveDialog, New-NetworkBulkDescriptionDialog, Show-NetworkBulkDescriptionDialog

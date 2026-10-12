# Interactive synthetic network configuration editor. No real VCD mutation path.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\..\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop

Import-Module (Join-Path $PSScriptRoot 'NetworkItemDialog.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NetworkBatchDialogs.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Application\Editing\NetworkWorkspace.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Application\Editing\NetworkRuleTemplates.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Access\SimulatorRbac.psm1') -ErrorAction Stop

# Register once using the actual WinForms FormClosingEventArgs.  `$args` is a
# PowerShell automatic variable and must not be used as an event parameter.
# Callback injection allows the real event path to be tested without a modal UI.
function Register-NetworkEditorCloseHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Form,
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][scriptblock]$ConfirmDiscard,
        [Parameter(Mandatory)][scriptblock]$GetWorkerCount,
        [Parameter(Mandatory)][scriptblock]$RequestCancellation
    )

    $Form.Add_FormClosing({
        param($sender, [System.Windows.Forms.FormClosingEventArgs]$closingEvent)

        if (-not $Model.Closing -and $Model.Dirty -and -not (& $ConfirmDiscard)) {
            # No: preserve the current form and dirty draft, and do not cancel work.
            $closingEvent.Cancel = $true
            return
        }

        if ([int](& $GetWorkerCount) -gt 0) {
            # No GUI shutdown while background operations may still be running.
            $closingEvent.Cancel = $true
            if (-not $Model.Closing) {
                $Model.Closing = $true
                & $RequestCancellation
            }
        }
    }.GetNewClosure())
}

function New-NetworkEditorForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)]$Logger,
          [ValidateSet('edgeFirewallRules','ipSets','manualIpReservations','plan','traffic')]
          [string]$InitialTab = 'edgeFirewallRules')
    if ($Configuration.vcd.mode -cne 'Simulator') { throw 'Network editor is disabled for live VCD; simulator mode required.' }
    # Resolve commands once, outside GetNewClosure handlers (PowerShell 5.1 module boundaries).
    $dispatchModule=Join-Path $Configuration.ApplicationRoot 'src\Runtime\Dispatcher.psm1'
    Import-Module $dispatchModule -ErrorAction Stop
    $commands=[pscustomobject]@{
        Start=(Get-Command Start-BackgroundOperation -ErrorAction Stop)
        Events=(Get-Command Receive-DispatcherEvents -ErrorAction Stop)
        Cancel=(Get-Command Request-OperationCancellation -ErrorAction Stop)
        Count=(Get-Command Get-RunningOperationCount -ErrorAction Stop)
        Close=(Get-Command Close-WorkerDispatcher -ErrorAction Stop)
        Set=(Get-Command Set-NetworkDraftItem -ErrorAction Stop)
        Remove=(Get-Command Remove-NetworkDraftItem -ErrorAction Stop)
        Move=(Get-Command Move-NetworkDraftRule -ErrorAction Stop)
        Copy=(Get-Command Copy-NetworkDocuments -ErrorAction Stop)
        ItemDialog=(Get-Command Show-NetworkItemDialog -ErrorAction Stop)
        Find=(Get-Command Find-NetworkDraftItems -ErrorAction Stop)
        Bulk=(Get-Command Set-NetworkDraftBulkRules -ErrorAction Stop)
        BulkDescription=(Get-Command Set-NetworkDraftBulkDescription -ErrorAction Stop)
        BulkDescriptionDialog=(Get-Command Show-NetworkBulkDescriptionDialog -ErrorAction Stop)
        BulkRemove=(Get-Command Remove-NetworkDraftBulkItems -ErrorAction Stop)
        BulkDialog=(Get-Command Show-NetworkBulkDialog -ErrorAction Stop)
        TemplateDialog=(Get-Command Show-NetworkTemplateDialog -ErrorAction Stop)
        TemplateSaveDialog=(Get-Command Show-NetworkTemplateSaveDialog -ErrorAction Stop)
        Templates=(Get-Command Get-NetworkRuleTemplates -ErrorAction Stop)
        NewFromTemplate=(Get-Command New-NetworkRuleFromTemplate -ErrorAction Stop)
        Role=(Get-Command Get-SimulatorActorRole -ErrorAction Stop)
        Permission=(Get-Command Test-SimulatorRolePermission -ErrorAction Stop)
    }
    $topologyPath=Join-Path $Configuration.ApplicationRoot 'simulator\topology.json'
    Import-Module (Join-Path $Configuration.ApplicationRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
    $topology=Import-SimulatorTopology -Path $topologyPath
    $templatePath=Join-Path $Configuration.ApplicationRoot 'templates\firewall-rules.json'
    $userTemplatePath=Join-Path $Configuration.ApplicationRoot 'templates\user-firewall-rules.json'
    $templates=@(& $commands.Templates -Path $templatePath -AdditionalPath $userTemplatePath)
    $dispatcher=New-WorkerDispatcher -ApplicationRoot $Configuration.ApplicationRoot -Logger $Logger -MaximumWorkers 2
    $model=[pscustomobject]@{NextTrafficPoll=[DateTime]::UtcNow;Scopes=@();GatewayId=[string]$Configuration.vcd.gatewayId;Baseline=$null;Documents=$null;CurrentList=@();Approved=$null;Active='';LastOperation='';Closing=$false;SuppressScopeChange=$false;PendingGateway='';Dirty=$false;CancelRequested=$false}
    $form=[System.Windows.Forms.Form]::new();$form.Name='NetworkEditorForm';$form.Text='VCD-NSXForge | Synthetic Network Editor';$form.StartPosition='CenterParent'
    $form.ClientSize=[System.Drawing.Size]::new(1040,740);$form.MinimumSize=[System.Drawing.Size]::new(1020,670)
    $form.Font=[System.Drawing.Font]::new('Segoe UI',9)
    $form.BackColor=[System.Drawing.SystemColors]::Window
    $form.ForeColor=[System.Drawing.SystemColors]::WindowText
    $form.AutoScaleMode=[System.Windows.Forms.AutoScaleMode]::Dpi
    $form.KeyPreview=$true
    $scopeLabel=[System.Windows.Forms.Label]::new();$scopeLabel.Text='Target domain / tier / gateway';$scopeLabel.SetBounds(16,13,220,22)
    $scope=[System.Windows.Forms.ComboBox]::new();$scope.Name='ScopeSelector';$scope.DropDownStyle='DropDownList';$scope.SetBounds(16,38,425,30)
    $actorLabel=[System.Windows.Forms.Label]::new();$actorLabel.Text='Acting identity (synthetic)';$actorLabel.SetBounds(463,13,220,22)
    $actor=[System.Windows.Forms.ComboBox]::new();$actor.Name='ActorSelector';$actor.DropDownStyle='DropDownList';$actor.SetBounds(463,38,210,30)
    foreach ($domain in @('DomainA','DomainB','DomainC')) { foreach ($tier in @(0,1)) { [void]$actor.Items.Add("$domain Tier $tier") } }
    $actor.SelectedIndex=0
    $actor.AccessibleName='Synthetic acting identity (not real authentication)'
    $refresh=[System.Windows.Forms.Button]::new();$refresh.Name='RefreshStateButton';$refresh.Text='Refresh';$refresh.SetBounds(700,36,92,32)
    $draft=[System.Windows.Forms.Button]::new();$draft.Name='SaveDraftButton';$draft.Text='Save draft';$draft.SetBounds(805,36,100,32)
    $apply=[System.Windows.Forms.Button]::new();$apply.Name='ApplySimulatorButton';$apply.Text='Apply (sim only)';$apply.SetBounds(916,36,112,32);$apply.Enabled=$false
    $roleLabel=[System.Windows.Forms.Label]::new();$roleLabel.Name='SimulatorRoleLabel';$roleLabel.Text='Synthetic role: loading';$roleLabel.SetBounds(695,10,327,23)
    $roleLabel.AccessibleName='Current synthetic access role';$roleLabel.AccessibleDescription='Demonstration only; not AD or VCD authorization.'
    $tabs=[System.Windows.Forms.TabControl]::new();$tabs.Name='NetworkEditorTabs';$tabs.SetBounds(16,85,1012,485);$tabs.Anchor='Top,Bottom,Left,Right'
    $lists=@{}; $pages=@{}; $filters=@{}
    foreach ($spec in @(@('edgeFirewallRules','Firewall rules'),@('ipSets','IP Sets'),@('manualIpReservations','IP reservations'))) {
        $kind=$spec[0]
        $page=[System.Windows.Forms.TabPage]::new();$page.Text=$spec[1];$page.Tag=$kind
        $layout=[System.Windows.Forms.TableLayoutPanel]::new();$layout.Dock='Fill';$layout.RowCount=3;$layout.ColumnCount=1
        $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,48)) | Out-Null
        $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,48)) | Out-Null
        $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) | Out-Null
        $toolbar=[System.Windows.Forms.FlowLayoutPanel]::new();$toolbar.Dock='Fill';$toolbar.Padding=[System.Windows.Forms.Padding]::new(8,7,0,0)
        $toolbar.Name=$kind+'Toolbar';$toolbar.AutoScroll=$false;$toolbar.WrapContents=$false
        $buttons=@()
        $addLabel=switch ($kind) { 'edgeFirewallRules' {'Add rule'}; 'ipSets' {'Add IP Set'}; default {'Add reservation'} }
        foreach ($info in @(@('Add',$addLabel),@('Edit','Edit selected'),@('Remove','Remove selected'),@('Up','Move up'),@('Down','Move down'),@('Bulk','Bulk edit'),@('Template','From template'),@('BulkRemove','Remove selected (bulk)'))) {
            $button=[System.Windows.Forms.Button]::new();$button.Name=($kind+$info[0]+'Button');$button.Text=$info[1]
            $button.AutoSize=$false;$button.Width=$(if ($info[0] -eq 'Add') {114} elseif ($info[0] -in @('Up','Down')) {80} elseif ($info[0] -eq 'BulkRemove') {174} else {112})
            $button.Height=33;$button.Margin=[System.Windows.Forms.Padding]::new(0,3,5,3)
            $button.Enabled=$false
            $toolbar.Controls.Add($button);$buttons+= $button
        }
        if ($kind -ne 'edgeFirewallRules') { foreach ($index in @(3,4,6)) { $buttons[$index].Visible=$false } }
        $list=[System.Windows.Forms.DataGridView]::new();$list.Name=($kind+'List')
        $list.Dock='Fill';$list.ReadOnly=$true;$list.AllowUserToAddRows=$false;$list.AllowUserToDeleteRows=$false
        $list.MultiSelect=$true;$list.SelectionMode='FullRowSelect';$list.RowHeadersVisible=$false
        $list.AutoSizeColumnsMode='Fill';$list.BackgroundColor=[System.Drawing.SystemColors]::Window
        $list.AccessibleName=($spec[1]+' resources');$list.AccessibleDescription='Use Ctrl or Shift to select multiple rows for bulk actions.'
        $list.EditMode='EditProgrammatically'
        if ($kind -eq 'edgeFirewallRules') {
            foreach ($col in @('Priority','Name','Action','Enabled','Source IP Sets','Destination IP Sets','Services','Logging')) { [void]$list.Columns.Add($col,$col) }
            $list.Columns['Priority'].FillWeight=45;$list.Columns['Name'].FillWeight=180
            $list.Columns['Source IP Sets'].FillWeight=135;$list.Columns['Destination IP Sets'].FillWeight=135
        }
        elseif ($kind -eq 'ipSets') { foreach ($col in @('Name','Addresses','Description')) { [void]$list.Columns.Add($col,$col) };$list.Columns['Addresses'].FillWeight=180 }
        else { foreach ($col in @('Reserved IP','Network ID','Description')) { [void]$list.Columns.Add($col,$col) };$list.Columns['Network ID'].FillWeight=185 }
        $filterBar=[System.Windows.Forms.FlowLayoutPanel]::new();$filterBar.Name=$kind+'FilterBar';$filterBar.Dock='Fill'
        $filterBar.Padding=[System.Windows.Forms.Padding]::new(8,5,0,0);$filterBar.WrapContents=$false
        $searchLabel=[System.Windows.Forms.Label]::new();$searchLabel.Text='Search';$searchLabel.AutoSize=$true;$searchLabel.Margin=[System.Windows.Forms.Padding]::new(0,9,8,0)
        $search=[System.Windows.Forms.TextBox]::new();$search.Name=$kind+'Search';$search.AccessibleName='Search '+$spec[1]
        $search.Width=310;$search.Margin=[System.Windows.Forms.Padding]::new(0,5,15,0)
        $actionFilter=[System.Windows.Forms.ComboBox]::new();$actionFilter.Name=$kind+'ActionFilter';$actionFilter.AccessibleName='Filter firewall action';$actionFilter.DropDownStyle='DropDownList';$actionFilter.Width=105
        foreach ($val in @('All','ALLOW','DROP','REJECT')) { [void]$actionFilter.Items.Add($val) };$actionFilter.SelectedIndex=0
        $statusFilter=[System.Windows.Forms.ComboBox]::new();$statusFilter.Name=$kind+'StatusFilter';$statusFilter.AccessibleName='Filter enabled status';$statusFilter.DropDownStyle='DropDownList';$statusFilter.Width=108
        foreach ($val in @('All','Enabled','Disabled')) { [void]$statusFilter.Items.Add($val) };$statusFilter.SelectedIndex=0
        $clearFilter=[System.Windows.Forms.Button]::new();$clearFilter.Name=$kind+'ClearFilter';$clearFilter.Text='Clear filters';$clearFilter.Width=115
        $saveTemplateButton=[System.Windows.Forms.Button]::new();$saveTemplateButton.Name=$kind+'SaveTemplateButton';$saveTemplateButton.Text='Save selected as template';$saveTemplateButton.Width=175;$saveTemplateButton.Enabled=$false
        $filterBar.Controls.AddRange([System.Windows.Forms.Control[]]@($searchLabel,$search,$actionFilter,$statusFilter,$clearFilter,$saveTemplateButton))
        if ($kind -ne 'edgeFirewallRules') { $actionFilter.Visible=$false;$statusFilter.Visible=$false;$saveTemplateButton.Visible=$false }
        $layout.Controls.Add($toolbar,0,0);$layout.Controls.Add($filterBar,0,1);$layout.Controls.Add($list,0,2)
        $filters[$kind]=[pscustomobject]@{Search=$search;Action=$actionFilter;Status=$statusFilter;Clear=$clearFilter;SaveTemplate=$saveTemplateButton}
        $page.Controls.Add($layout);[void]$tabs.TabPages.Add($page)
        $lists[$kind]=$list;$pages[$kind]=[pscustomobject]@{Page=$page;Buttons=$buttons}
    }
    $planPage=[System.Windows.Forms.TabPage]::new();$planPage.Text='Change plan';$planPage.Name='ChangePlanTab'
    $planDetails=[System.Windows.Forms.TextBox]::new();$planDetails.Name='PlanDiffDetails'
    $planDetails.Multiline=$true;$planDetails.ReadOnly=$true;$planDetails.ScrollBars='Both'
    $planDetails.Font=[System.Drawing.Font]::new('Consolas',9);$planDetails.WordWrap=$false;$planDetails.AccessibleName='Proposed network change plan'
    $planDetails.SetBounds(12,12,962,414);$planDetails.Anchor='Top,Bottom,Left,Right'
    $planPage.Controls.Add($planDetails);[void]$tabs.TabPages.Add($planPage)
    $trafficPage=[System.Windows.Forms.TabPage]::new();$trafficPage.Text='Synthetic traffic' ;$trafficPage.Name='TrafficMonitorTab'
    $src=[System.Windows.Forms.TextBox]::new();$src.Name='FlowSource';$src.SetBounds(18,28,180,28);$src.Text='10.50.20.10'
    $dst=[System.Windows.Forms.TextBox]::new();$dst.Name='FlowDestination';$dst.SetBounds(212,28,180,28);$dst.Text='10.50.20.11'
    $protocol=[System.Windows.Forms.ComboBox]::new();$protocol.Name='FlowProtocol';$protocol.DropDownStyle='DropDownList';$protocol.Items.AddRange([object[]]@('TCP','UDP','ICMP'));$protocol.SelectedIndex=0;$protocol.SetBounds(406,28,100,28)
    $port=[System.Windows.Forms.NumericUpDown]::new();$port.Name='FlowPort';$port.Minimum=1;$port.Maximum=65535;$port.Value=443;$port.SetBounds(520,28,93,28)
    $trafficHint=[System.Windows.Forms.Label]::new();$trafficHint.Name='TrafficAutoRefreshLabel';$trafficHint.Text='Live synthetic traffic - refreshes every 2 seconds';$trafficHint.SetBounds(778,30,210,26);$trafficHint.Anchor='Top,Right'
    $sendFlow=[System.Windows.Forms.Button]::new();$sendFlow.Name='SimulateFlowButton';$sendFlow.Text='Simulate flow';$sendFlow.SetBounds(635,27,134,30)
    $flowHistory=[System.Windows.Forms.ListBox]::new();$flowHistory.Name='TrafficEvents';$flowHistory.SetBounds(18,75,951,355);$flowHistory.Anchor='Top,Left,Right,Bottom';$flowHistory.Font=[System.Drawing.Font]::new('Consolas',9);$flowHistory.AccessibleName='Synthetic traffic history';$flowHistory.AccessibleDescription='Most recent simulated flows, verdict and matching firewall rule'
    $trafficPage.Controls.AddRange([System.Windows.Forms.Control[]]@($src,$dst,$protocol,$port,$sendFlow,$flowHistory,$trafficHint));[void]$tabs.TabPages.Add($trafficPage)
    # Navigate from the landing dashboard without loading a separate implementation.
    $initialPages = @{ edgeFirewallRules = $pages['edgeFirewallRules'].Page; ipSets = $pages['ipSets'].Page; manualIpReservations = $pages['manualIpReservations'].Page; plan = $planPage; traffic = $trafficPage }
    $tabs.SelectedTab = $initialPages[$InitialTab]
    $plan=[System.Windows.Forms.Button]::new();$plan.Name='GeneratePlanButton';$plan.Text='Generate plan';$plan.SetBounds(16,585,160,34);$plan.Anchor='Bottom,Left'
    $cancel=[System.Windows.Forms.Button]::new();$cancel.Name='CancelEditorOperation';$cancel.Text='Cancel worker';$cancel.SetBounds(189,585,135,34);$cancel.Anchor='Bottom,Left';$cancel.Enabled=$false
    $status=[System.Windows.Forms.Label]::new();$status.Name='EditorStatus';$status.SetBounds(350,585,670,50);$status.Anchor='Bottom,Left,Right';$status.Text='Loading synthetic scopes...'
    $report=[System.Windows.Forms.TextBox]::new();$report.Name='PlanSummaryText';$report.Multiline=$true;$report.ReadOnly=$true;$report.ScrollBars='Vertical';$report.SetBounds(16,638,1012,78);$report.Anchor='Bottom,Left,Right';$report.AccessibleName='Network editor notifications';$report.Text='Changes are drafts until you generate and explicitly apply a plan.'
    $form.Controls.AddRange([System.Windows.Forms.Control[]]@($scopeLabel,$scope,$actorLabel,$actor,$roleLabel,$refresh,$draft,$apply,$tabs,$plan,$cancel,$status,$report))

    $currentRole={
        if ($null -eq $model.Baseline) { return 'Viewer' }
        $identity=([string]$actor.SelectedItem).Split(' ')
        $roleInfo=& $commands.Role -Dataset $topology -ActorDomain $identity[0] -ActorTier ([int]$identity[2]) -TargetDomain ([string]$model.Baseline.domain) -TargetTier ([int]$model.Baseline.tier)
        return [string]$roleInfo.Role
    }.GetNewClosure()
    $canDo={param([string]$operation)
        return [bool](& $commands.Permission -Role (& $currentRole) -Operation $operation)
    }.GetNewClosure()
    $render={
        if ($null -eq $model.Documents) { return }
        $ipSetNames=@{}
        foreach ($ipSet in @($model.Documents.ipSets.items)) { $ipSetNames[[string]$ipSet.key]=[string]$ipSet.name }
        foreach ($kind in @('edgeFirewallRules','ipSets','manualIpReservations')) {
            $list=$lists[$kind];$list.Rows.Clear()
            $filter=$filters[$kind]
            $items=@(& $commands.Find -Documents $model.Documents -ResourceKind $kind -Search $filter.Search.Text -Action ([string]$filter.Action.SelectedItem) -Status ([string]$filter.Status.SelectedItem))
            foreach ($item in $items) {
                if ($kind -eq 'edgeFirewallRules') {
                    $summary=if (@($item.services).Count -eq 0) { 'Any' } else { (@($item.services | ForEach-Object { $_.protocol + ' ' + (@($_.ports) -join ',') }) -join '; ') }
                    $sourceNames=@($item.sourceIpSets | ForEach-Object { if ($ipSetNames.ContainsKey([string]$_)) { $ipSetNames[[string]$_] } else { [string]$_ } })
                    $destinationNames=@($item.destinationIpSets | ForEach-Object { if ($ipSetNames.ContainsKey([string]$_)) { $ipSetNames[[string]$_] } else { [string]$_ } })
                    $index=$list.Rows.Add([int]$item.order,$item.name,$item.action,[bool]$item.enabled, $(if ($sourceNames.Count) { $sourceNames -join ', ' } else { 'Any' }), $(if ($destinationNames.Count) { $destinationNames -join ', ' } else { 'Any' }),$summary,[bool]$item.logging)
                }
                elseif ($kind -eq 'ipSets') { $index=$list.Rows.Add($item.name,(@($item.addresses) -join ', '),$item.description) }
                else { $index=$list.Rows.Add($item.address,$item.networkId,$item.description) }
                $list.Rows[$index].Tag=$item
            }
            $list.ClearSelection()
            $enabled=(-not $model.Active -and -not $model.Closing -and (& $canDo 'Edit'))
            $pages[$kind].Buttons[0].Enabled=$enabled
            $hasSelection=($list.SelectedRows.Count -gt 0)
            $pages[$kind].Buttons[1].Enabled=$enabled -and ($list.SelectedRows.Count -eq 1)
            $pages[$kind].Buttons[2].Enabled=$enabled -and ($list.SelectedRows.Count -eq 1)
            if ($kind -eq 'edgeFirewallRules') {
                $pages[$kind].Buttons[3].Enabled=$enabled -and ($list.SelectedRows.Count -eq 1)
                $pages[$kind].Buttons[4].Enabled=$enabled -and ($list.SelectedRows.Count -eq 1)
                $pages[$kind].Buttons[5].Enabled=$enabled -and $hasSelection
                $pages[$kind].Buttons[6].Enabled=$enabled
            }
            if ($kind -ne 'edgeFirewallRules') { $pages[$kind].Buttons[5].Enabled=$enabled -and $hasSelection }
            $pages[$kind].Buttons[7].Enabled=$enabled -and $hasSelection
            $filters[$kind].SaveTemplate.Enabled=($kind -eq 'edgeFirewallRules' -and $enabled -and $list.SelectedRows.Count -eq 1)
        }
        $role=[string](& $currentRole)
        $roleLabel.Text="Synthetic role: $role"
        $roleLabel.AccessibleDescription="Role $role for selected actor and target. Not authenticated to Active Directory or VMware."
        $draft.Enabled=(-not $model.Active -and (& $canDo 'SaveDraft'))
        $plan.Enabled=(-not $model.Active -and (& $canDo 'Plan'))
        $apply.Enabled=($null -ne $model.Approved -and -not $model.Approved.plan.blocked -and -not $model.Active -and (& $canDo 'Apply'))
    }.GetNewClosure()
    $invalidate={ $model.Dirty=$true;$model.Approved=$null;$apply.Enabled=$false;$planDetails.Text='Plan invalidated by draft edit.';$report.Text='Draft changed. Generate a new plan before apply.' }.GetNewClosure()
    $start={
        param([string]$name,[hashtable]$parameters=@{})
        if ($model.Active -or $model.Closing) { return }
        try {
            if ($name -like 'Simulator*') { $parameters.ApiUrl=[string]$Configuration.vcd.apiUrl }
            $model.Active=& $commands.Start -Dispatcher $dispatcher -Operation $name -Arguments $parameters
            $model.CancelRequested=$false
            $model.LastOperation=$name
            $cancel.Enabled=($name -ne 'SimulatorTrafficRead')
            if ($name -ne 'SimulatorTrafficRead') { $status.Text="Working on background runspace: $name" }
            # Even brief read-only polls must prevent scope changes; otherwise
            # a scope switch could lose its state-load request while polling.
            $refresh.Enabled=$false;$plan.Enabled=$false;$apply.Enabled=$false;$draft.Enabled=$false;$scope.Enabled=$false
            foreach ($resourceType in @('edgeFirewallRules','ipSets','manualIpReservations')) { foreach ($b in $pages[$resourceType].Buttons) { $b.Enabled=$false } }
        }
        catch {
            $status.Text="Operation start failed: $($_.Exception.Message)"
            $model.Active=''
            $cancel.Enabled=$false
            if ($null -ne $model.Documents) { & $render }
        }
    }.GetNewClosure()

    foreach ($kind in @('edgeFirewallRules','ipSets','manualIpReservations')) {
        $controls=$pages[$kind].Buttons;$list=$lists[$kind];$filterSet=$filters[$kind]
        $refreshGrid={if ($null -ne $model.Documents) { & $render }}.GetNewClosure()
        $filterSet.Search.Add_TextChanged($refreshGrid)
        $filterSet.Action.Add_SelectedIndexChanged($refreshGrid)
        $filterSet.Status.Add_SelectedIndexChanged($refreshGrid)
        $filterSet.Clear.Add_Click({$filterSet.Search.Clear();$filterSet.Action.SelectedIndex=0;$filterSet.Status.SelectedIndex=0;& $refreshGrid}.GetNewClosure())
        $list.Add_SelectionChanged({
            $selected=($list.SelectedRows.Count -gt 0)
            $canEdit=(-not $model.Active -and -not $model.Closing -and (& $canDo 'Edit'))
            $controls[1].Enabled=$canEdit -and ($list.SelectedRows.Count -eq 1)
            $controls[2].Enabled=$canEdit -and ($list.SelectedRows.Count -eq 1)
            $controls[7].Enabled=$canEdit -and $selected
            $filterSet.SaveTemplate.Enabled=($kind -eq 'edgeFirewallRules' -and $canEdit -and $list.SelectedRows.Count -eq 1)
            if ($kind -eq 'edgeFirewallRules') {
                foreach ($index in @(3,4)) { $controls[$index].Enabled=$canEdit -and ($list.SelectedRows.Count -eq 1) }
                $controls[5].Enabled=$canEdit -and $selected
            } else { $controls[5].Enabled=$canEdit -and $selected }
        }.GetNewClosure())
        $addHandler={
            if ($null -eq $model.Documents -or $model.Active -or -not (& $canDo 'Edit')) { return }
            try {
                $item=& $commands.ItemDialog -ResourceKind $kind -Documents $model.Documents -NetworkId ([string]$model.Baseline.networkId) -NetworkLabel ("$($model.Baseline.domain) Tier $($model.Baseline.tier) network") -Owner $form
                if ($null -ne $item) { $model.Documents=& $commands.Set -Documents $model.Documents -ResourceKind $kind -Item $item -Create;& $invalidate;& $render }
            }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Unable to add resource') | Out-Null }
        }.GetNewClosure()
        $editHandler={
            if ($null -eq $model.Documents -or $model.Active -or -not (& $canDo 'Edit') -or $null -eq $list.CurrentRow) { return }
            $original=$list.CurrentRow.Tag
            try {
                $item=& $commands.ItemDialog -ResourceKind $kind -Documents $model.Documents -Original $original -NetworkId ([string]$model.Baseline.networkId) -NetworkLabel ("$($model.Baseline.domain) Tier $($model.Baseline.tier) network") -Owner $form
                if ($null -ne $item) {
                    $model.Documents=& $commands.Set -Documents $model.Documents -ResourceKind $kind -Item $item
                    & $invalidate;& $render
                }
            }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Unable to edit resource') | Out-Null }
        }.GetNewClosure()
        $removeHandler={
            if ($null -eq $model.Documents -or $model.Active -or -not (& $canDo 'Edit') -or $null -eq $list.CurrentRow) { return }
            $item=$list.CurrentRow.Tag
            if ([System.Windows.Forms.MessageBox]::Show("Remove '$($item.key)' from the draft?",'Confirm removal','YesNo','Warning') -ne 'Yes') { return }
            try {
                $model.Documents=& $commands.Remove -Documents $model.Documents -ResourceKind $kind -Key $item.key
                if ($kind -eq 'edgeFirewallRules') {
                    $idx=0;foreach ($rule in @($model.Documents.edgeFirewallRules.items | Sort-Object order)) { $rule.order=$idx; $idx++ }
                }
                & $invalidate;& $render
            }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Unable to remove resource') | Out-Null }
        }.GetNewClosure()
        $upHandler={
            if ($model.Active -or -not (& $canDo 'Edit') -or $null -eq $list.CurrentRow -or $null -eq $model.Documents) { return }
            $item=$list.CurrentRow.Tag
            try { $model.Documents=& $commands.Move -Documents $model.Documents -Key $item.key -Direction Up;& $invalidate;& $render }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Move failed') | Out-Null }
        }.GetNewClosure()
        $downHandler={
            if ($model.Active -or -not (& $canDo 'Edit') -or $null -eq $list.CurrentRow -or $null -eq $model.Documents) { return }
            $item=$list.CurrentRow.Tag
            try { $model.Documents=& $commands.Move -Documents $model.Documents -Key $item.key -Direction Down;& $invalidate;& $render }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Move failed') | Out-Null }
        }.GetNewClosure()
        $bulkHandler={
            if ($null -eq $model.Documents -or $model.Active -or -not (& $canDo 'BulkEdit')) { return }
            $keys=@($list.SelectedRows | ForEach-Object { [string]$_.Tag.key })
            if ($keys.Count -lt 1) { return }
            try {
                if ($kind -eq 'edgeFirewallRules') {
                    $values=& $commands.BulkDialog -SelectedCount $keys.Count -Owner $form
                    if ($null -ne $values) {
                        $model.Documents=& $commands.Bulk -Documents $model.Documents -Keys $keys -Action $values.Action -Status $values.Status -Logging $values.Logging
                        & $invalidate; & $render
                    }
                } else {
                    $values=& $commands.BulkDescriptionDialog -SelectedCount $keys.Count -Owner $form
                    if ($null -ne $values) {
                        $model.Documents=& $commands.BulkDescription -Documents $model.Documents -ResourceKind $kind -Keys $keys -Description $values.Description
                        & $invalidate; & $render
                    }
                }
            }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Unable to bulk edit rules') | Out-Null }
        }.GetNewClosure()
        $bulkRemoveHandler={
            if ($null -eq $model.Documents -or $model.Active -or -not (& $canDo 'BulkEdit')) { return }
            $keys=@($list.SelectedRows | ForEach-Object { [string]$_.Tag.key })
            if ($keys.Count -lt 1) { return }
            if ([System.Windows.Forms.MessageBox]::Show("Remove $($keys.Count) selected resources from the draft?",'Confirm bulk removal','YesNo','Warning') -ne 'Yes') { return }
            try { $model.Documents=& $commands.BulkRemove -Documents $model.Documents -ResourceKind $kind -Keys $keys;& $invalidate;& $render }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Bulk removal blocked') | Out-Null }
        }.GetNewClosure()
        $saveTemplateHandler={
            if ($kind -ne 'edgeFirewallRules' -or $model.Active -or -not (& $canDo 'UseTemplate') -or $list.SelectedRows.Count -ne 1) { return }
            $rule=$list.CurrentRow.Tag
            $templateName=& $commands.TemplateSaveDialog -DefaultName ([string]$rule.name) -Owner $form
            if ([string]::IsNullOrWhiteSpace($templateName)) { return }
            & $start 'SaveRuleTemplate' @{Rule=$rule;TemplateName=$templateName;TemplatePath=$userTemplatePath;BuiltInPath=$templatePath}
        }.GetNewClosure()
        $filterSet.SaveTemplate.Add_Click($saveTemplateHandler)
        $templateHandler={
            if ($null -eq $model.Documents -or $model.Active -or -not (& $canDo 'UseTemplate')) { return }
            try {
                $templates=@(& $commands.Templates -Path $templatePath -AdditionalPath $userTemplatePath)
                $selection=& $commands.TemplateDialog -Templates $templates -Owner $form
                if ($null -eq $selection) { return }
                $prototype=& $commands.NewFromTemplate -Documents $model.Documents -Template $selection.Template -Name $selection.Name
                $item=& $commands.ItemDialog -ResourceKind edgeFirewallRules -Documents $model.Documents -Prefill $prototype -NetworkId ([string]$model.Baseline.networkId) -Owner $form
                if ($null -ne $item) { $model.Documents=& $commands.Set -Documents $model.Documents -ResourceKind edgeFirewallRules -Item $item -Create;& $invalidate;& $render }
            }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Unable to create rule from template') | Out-Null }
        }.GetNewClosure()
        $controls[0].Add_Click($addHandler);$controls[1].Add_Click($editHandler);$controls[2].Add_Click($removeHandler)
        $controls[7].Add_Click($bulkRemoveHandler)
        $controls[5].Add_Click($bulkHandler)
        if ($kind -eq 'edgeFirewallRules') { $controls[6].Add_Click($templateHandler) }
        if ($kind -eq 'edgeFirewallRules') { $controls[3].Add_Click($upHandler);$controls[4].Add_Click($downHandler) }
    }
    $actor.Add_SelectedIndexChanged({if ($null -ne $model.Documents) { & $render }}.GetNewClosure())
    $form.Add_KeyDown({param($sender,$event)
        if ($event.Control -and $event.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            $kind=[string]$tabs.SelectedTab.Tag
            if ($filters.ContainsKey($kind)) { $filters[$kind].Search.Focus();$event.SuppressKeyPress=$true }
        }
    }.GetNewClosure())
    $scope.Add_SelectedIndexChanged({
        if ($model.SuppressScopeChange -or $scope.SelectedIndex -lt 0) { return }
        if ($model.Dirty -and [System.Windows.Forms.MessageBox]::Show('Switch scope? Draft changes will be discarded.','Change scope','YesNo','Warning') -ne 'Yes') {
            $model.SuppressScopeChange=$true
            for ($i=0;$i -lt $model.Scopes.Count;$i++) { if ($model.Scopes[$i].gatewayId -ceq $model.GatewayId) { $scope.SelectedIndex=$i;break } }
            $model.SuppressScopeChange=$false
            return
        }
        $model.GatewayId=[string]$model.Scopes[$scope.SelectedIndex].gatewayId
        $model.Documents=$null;$model.Baseline=$null;$model.Approved=$null;$model.Dirty=$false
        & $start 'SimulatorLoadState' @{GatewayId=$model.GatewayId}
    }.GetNewClosure())
    $refresh.Add_Click({
        if ($model.Dirty -and [System.Windows.Forms.MessageBox]::Show('Discard draft edits and refresh the simulator state?','Refresh scope','YesNo','Warning') -ne 'Yes') { return }
        & $start 'SimulatorLoadState' @{GatewayId=$model.GatewayId}
    }.GetNewClosure())
    $plan.Add_Click({
        if ($null -eq $model.Documents -or -not (& $canDo 'Plan')) { return }
        & $start 'SimulatorPlan' @{Baseline=$model.Baseline;Documents=(& $commands.Copy $model.Documents);OutputDirectory=(Join-Path $Configuration.ApplicationRoot $Configuration.state.reportsDirectory)}
    }.GetNewClosure())
    $draft.Add_Click({
        if ($null -eq $model.Documents -or -not (& $canDo 'SaveDraft')) { return }
        & $start 'SimulatorSaveDraft' @{Documents=(& $commands.Copy $model.Documents);StateRoot=(Join-Path $Configuration.ApplicationRoot $Configuration.state.directory);Scope=([string]$model.Baseline.domain+'-t'+$model.Baseline.tier).ToLowerInvariant()}
    }.GetNewClosure())
    $apply.Add_Click({
        if ($null -eq $model.Approved -or $model.Approved.plan.blocked -or -not (& $canDo 'Apply')) { return }
        $counts=$model.Approved.plan.summary
        $message="Apply to LOCAL SIMULATOR ONLY?`nCreate $($counts.Create), update $($counts.Update), move $($counts.Move), delete $($counts.Delete).`n`nThis will NOT affect VCD or NSX."
        if ([System.Windows.Forms.MessageBox]::Show($message,'Confirm synthetic apply','YesNo','Warning') -ne 'Yes') { return }
        $actorParts=([string]$actor.SelectedItem).Split(' ')
        & $start 'SimulatorApply' @{Approved=$model.Approved;ActorDomain=$actorParts[0];ActorTier=[int]$actorParts[2]}
    }.GetNewClosure())
    $protocol.Add_SelectedIndexChanged({ $port.Enabled=([string]$protocol.SelectedItem -ne 'ICMP') }.GetNewClosure())
    $sendFlow.Add_Click({
        $targetPort=if ([string]$protocol.SelectedItem -eq 'ICMP') { 0 } else { [int]$port.Value }
        & $start 'SimulatorTraffic' @{GatewayId=$model.GatewayId;SourceIp=$src.Text;DestinationIp=$dst.Text;Protocol=[string]$protocol.SelectedItem;DestinationPort=$targetPort}
    }.GetNewClosure())
    $cancel.Add_Click({ if ($model.Active -and -not $model.CancelRequested) { & $commands.Cancel -Dispatcher $dispatcher -OperationId $model.Active;$model.CancelRequested=$true;$cancel.Enabled=$false;$status.Text='Cancellation requested...' } }.GetNewClosure())
    $timer=[System.Windows.Forms.Timer]::new();$timer.Interval=100
    $timer.Add_Tick({
        foreach ($evt in @(& $commands.Events -Dispatcher $dispatcher)) {
            if ($evt.OperationId -cne $model.Active) { continue }
            if ($evt.Type -eq 'CancellationDelayed') { $status.Text='WARNING: '+$evt.Message; continue }
            if ($evt.Type -eq 'SimulatorData') {
                switch ($evt.Name) {
                    'Scopes' {
                        $model.Scopes=@($evt.Payload.scopes);$model.SuppressScopeChange=$true;$scope.Items.Clear()
                        $chosen=0
                        for ($i=0;$i -lt $model.Scopes.Count;$i++) {
                            $item=$model.Scopes[$i];[void]$scope.Items.Add("$($item.domain) | Tier $($item.tier) | $($item.name)")
                            if ($item.gatewayId -ceq $model.GatewayId) { $chosen=$i }
                        }
                        $scope.SelectedIndex=$chosen;$model.SuppressScopeChange=$false
                        $model.GatewayId=[string]$model.Scopes[$chosen].gatewayId
                        $model.PendingGateway=$model.GatewayId
                    }
                    'State' {
                        $model.Baseline=$evt.Payload.State;$model.Documents=[ordered]@{}
                        foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $model.Documents[$kind]=$evt.Payload.State.documents.$kind }
                        $flowHistory.Items.Clear()
                        foreach ($traffic in @($evt.Payload.Events | Sort-Object timestampUtc -Descending)) {
                            [void]$flowHistory.Items.Add(('{0} {1} {2}:{3} -> {4}:{5} | {6}' -f $traffic.timestampUtc,$traffic.verdict,$traffic.sourceIp,$traffic.protocol,$traffic.destinationIp,$traffic.destinationPort,$traffic.matchedRuleName))
                        }
                        $model.Approved=$null;$model.Dirty=$false;& $render
                        $report.Text="Scope $($model.Baseline.domain) Tier $($model.Baseline.tier) | Revision $($model.Baseline.revision) | Synthetic state loaded"
                    }
                    'Plan' {
                        $model.Approved=$evt.Payload.Approved;$report.Text=$evt.Payload.Summary
                        $lines=[System.Collections.Generic.List[string]]::new()
                        $lines.Add('SIMULATOR PLAN - no real VMware changes')
                        $lines.Add('Base revision: '+$model.Approved.expectedRevision)
                        foreach ($change in @($model.Approved.plan.actions)) {
                            $marker=switch ($change.Change) {'Create' {'+'};'Delete' {'-'};'Update' {'~'};'Move' {'>'}}
                            $lines.Add(('{0} {1}/{2} ({3})' -f $marker,$change.ResourceKind,$change.Key,$change.Change))
                            if ($null -ne $change.Before) { $lines.Add('BEFORE: '+(ConvertTo-Json $change.Before -Compress -Depth 15)) }
                            if ($null -ne $change.After) { $lines.Add('AFTER:  '+(ConvertTo-Json $change.After -Compress -Depth 15)) }
                        }
                        if ($model.Approved.plan.blocked) { $lines.Add('BLOCKED: unsafe plan cannot be applied') }
                        $planDetails.Text=$lines -join [Environment]::NewLine
                        $tabs.SelectedTab=$planPage
                        & $render
                    }
                    'Apply' { $model.Approved=$null;$report.Text='Synthetic apply succeeded. '+$evt.Payload.Message }
                    'TrafficHistory' {
                        $flowHistory.Items.Clear()
                        foreach ($traffic in @($evt.Payload.Events | Sort-Object timestampUtc -Descending)) {
                            [void]$flowHistory.Items.Add(('{0} {1} {2}:{3} -> {4}:{5} | {6}' -f $traffic.timestampUtc,$traffic.verdict,$traffic.sourceIp,$traffic.protocol,$traffic.destinationIp,$traffic.destinationPort,$traffic.matchedRuleName))
                        }
                    }
                    'Traffic' {
                        $flowHistory.Items.Clear()
                        foreach ($traffic in @($evt.Payload.Events | Sort-Object timestampUtc -Descending)) {
                            [void]$flowHistory.Items.Add(('{0} {1} {2}:{3} -> {4}:{5} | {6}' -f $traffic.timestampUtc,$traffic.verdict,$traffic.sourceIp,$traffic.protocol,$traffic.destinationIp,$traffic.destinationPort,$traffic.matchedRuleName))
                        }
                        $report.Text=$evt.Payload.Message
                    }
                    'Draft' { $report.Text=$evt.Payload.Message }
                    'TemplateSaved' { $report.Text=$evt.Payload.Message }
                }
                $status.Text=$evt.Message
            }
            elseif ($evt.Type -in @('Completed','Failed','Cancelled')) {
                $old=$model.LastOperation;$model.Active='';$model.CancelRequested=$false;$cancel.Enabled=$false
                $refresh.Enabled=-not $model.Closing;$plan.Enabled=-not $model.Closing;$draft.Enabled=-not $model.Closing;$scope.Enabled=-not $model.Closing
                $apply.Enabled=($null -ne $model.Approved -and -not $model.Approved.plan.blocked -and -not $model.Closing -and (& $canDo 'Apply'))
                if ($null -ne $model.Documents) { & $render }
                if ($evt.Type -eq 'Failed') { $status.Text='ERROR: '+$evt.Message }
                elseif ($evt.Type -eq 'Cancelled') { $status.Text='Operation cancelled' }
                elseif ($old -ne 'SimulatorTrafficRead') { $status.Text='Completed: '+$old }
                if ($evt.Type -eq 'Completed' -and $old -eq 'SimulatorScopes' -and $model.PendingGateway) {
                    $gateway=$model.PendingGateway;$model.PendingGateway=''; & $start 'SimulatorLoadState' @{GatewayId=$gateway}
                }
                if ($evt.Type -eq 'Completed' -and $old -eq 'SimulatorApply') { & $start 'SimulatorLoadState' @{GatewayId=$model.GatewayId} }
            }
        }
        # Poll only while monitoring is visible; never block the UI thread or
        # interrupt draft, plan, apply or manually submitted traffic operations.
        if (-not $model.Closing -and -not $model.Active -and $model.GatewayId -and
            $tabs.SelectedTab -eq $trafficPage -and
            [DateTime]::UtcNow -ge $model.NextTrafficPoll) {
            $model.NextTrafficPoll=[DateTime]::UtcNow.AddSeconds(2)
            & $start 'SimulatorTrafficRead' @{GatewayId=$model.GatewayId}
        }
        if ($model.Closing -and (& $commands.Count -Dispatcher $dispatcher) -eq 0) { $timer.Stop();$form.Close() }
    }.GetNewClosure())
    # Keep the event handler independent of the PowerShell `$args` automatic variable.
    # The callbacks are captured explicitly for Windows PowerShell 5.1 modules.
    $registerClose = Get-Command Register-NetworkEditorCloseHandler -ErrorAction Stop
    $confirmDiscard = {
        [System.Windows.Forms.MessageBox]::Show('Discard unapplied draft changes?',
            'Close network editor','YesNo','Warning') -eq [System.Windows.Forms.DialogResult]::Yes
    }.GetNewClosure()
    $countWorkers = { & $commands.Count -Dispatcher $dispatcher }.GetNewClosure()
    $cancelWorkers = {
        $cancel.Enabled=$false
        & $commands.Cancel -Dispatcher $dispatcher
        $status.Text='Closing after background worker exits...'
    }.GetNewClosure()
    & $registerClose -Form $form -Model $model -ConfirmDiscard $confirmDiscard `
        -GetWorkerCount $countWorkers -RequestCancellation $cancelWorkers
    $form.Add_Shown({$timer.Start(); & $start 'SimulatorScopes' @{} }.GetNewClosure())
    return [pscustomobject]@{Form=$form;Timer=$timer;Dispatcher=$dispatcher;CloseCommand=$commands.Close}
}
Export-ModuleMember -Function New-NetworkEditorForm, Register-NetworkEditorCloseHandler

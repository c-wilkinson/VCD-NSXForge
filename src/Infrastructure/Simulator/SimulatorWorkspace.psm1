# Local simulator workspace. Never imported by the production VCD HTTP transport.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Traffic\Traffic.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\StateModel.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Planning\Planning.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Access\SimulatorRbac.psm1') -ErrorAction Stop

function Get-SimulatorItemKey {
    param([string]$Id)
    if ($Id -match '([0-9a-fA-F-]{36})$') { return 'vcd-' + $Matches[1].ToLowerInvariant() }
    throw 'Synthetic item is missing a stable UUID.'
}

function New-SimulatorGuid {
    param([string]$Scope,[string]$Kind,[string]$Key)
    $hash=[System.Security.Cryptography.SHA256]::Create()
    try { $bytes=$hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Scope|$Kind|$Key")) }
    finally { $hash.Dispose() }
    return ([guid]::new([byte[]]$bytes[0..15])).ToString()
}

function ConvertFrom-SimulatorGateway {
    param([Parameter(Mandatory)]$Gateway)
    $sets=@(); $refs=@{}
    foreach ($group in @($Gateway.ipSets)) {
        $key=Get-SimulatorItemKey -Id ([string]$group.id); $refs[[string]$group.id]=$key
        $sets+= [pscustomobject]@{key=$key;name=[string]$group.name;description=[string]$group.description;addresses=@($group.ipAddresses)}
    }
    $rules=@(); $index=0
    foreach ($rule in @($Gateway.firewall.userDefinedRules)) {
        $sources=@(); foreach ($entry in @($rule.sourceFirewallGroups)) { if (-not $refs.ContainsKey([string]$entry.id)) { throw 'Unknown simulator source Firewall Group.' }; $sources+= $refs[[string]$entry.id] }
        $destinations=@(); foreach ($entry in @($rule.destinationFirewallGroups)) { if (-not $refs.ContainsKey([string]$entry.id)) { throw 'Unknown simulator target Firewall Group.' }; $destinations+= $refs[[string]$entry.id] }
        $services=@()
        if ($null -ne $rule.PSObject.Properties['simulatorServices']) { $services=@($rule.simulatorServices) }
        $rules+= [pscustomobject]@{key=(Get-SimulatorItemKey $rule.id);name=[string]$rule.name;description=[string]$rule.description;order=$index;action=[string]$rule.actionValue;enabled=[bool]$rule.active;logging=[bool]$rule.logging;sourceIpSets=@($sources);destinationIpSets=@($destinations);services=@($services)}
        $index++
    }
    $reservations=@()
    foreach ($reservation in @($Gateway.reservations)) {
        $reservations+= [pscustomobject]@{key=(Get-SimulatorItemKey $reservation.id);networkId=[string]$reservation.networkRef.id;address=[string]$reservation.ipAddresses;description=[string]$reservation.description}
    }
    $docs=[ordered]@{}
    $values=@{ipSets=@($sets);edgeFirewallRules=@($rules);manualIpReservations=@($reservations)}
    foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $docs[$kind]=[pscustomobject]@{schemaVersion=2;resourceKind=$kind;items=@($values[$kind])} }
    $null=Test-NetworkStateView -Documents $docs
    return $docs
}

function ConvertTo-SimulatorGateway {
    param([Parameter(Mandatory)]$Gateway,[Parameter(Mandatory)]$Documents)
    $groupIds=@{}; $groups=@()
    foreach ($item in @($Documents['ipSets'].items)) {
        $id='urn:vcloud:firewallGroup:'+(New-SimulatorGuid $Gateway.gatewayId 'ipSets' $item.key)
        if ($item.key -match '^vcd-([0-9a-fA-F-]{36})$') { $id='urn:vcloud:firewallGroup:'+$Matches[1] }
        $groupIds[[string]$item.key]=$id
        $description=if ($null -ne $item.PSObject.Properties['description']) { [string]$item.description } else { '' }
        $groups+= [pscustomobject]@{id=$id;name=$item.name;description=$description;typeValue='IP_SET';ipAddresses=@($item.addresses)}
    }
    $rules=@()
    foreach ($item in @($Documents['edgeFirewallRules'].items | Sort-Object order)) {
        $id='urn:vcloud:firewallRule:'+(New-SimulatorGuid $Gateway.gatewayId 'edgeFirewallRules' $item.key)
        if ($item.key -match '^vcd-([0-9a-fA-F-]{36})$') { $id='urn:vcloud:firewallRule:'+$Matches[1] }
        $src=@(); foreach ($key in @($item.sourceIpSets)) { $src+= [pscustomobject]@{id=$groupIds[[string]$key]} }
        $dst=@(); foreach ($key in @($item.destinationIpSets)) { $dst+= [pscustomobject]@{id=$groupIds[[string]$key]} }
        $description=if ($null -ne $item.PSObject.Properties['description']) { [string]$item.description } else { '' }
        $ruleObj=[pscustomobject]@{id=$id;name=$item.name;description=$description;sourceFirewallGroups=@($src);destinationFirewallGroups=@($dst);actionValue=$item.action;active=$item.enabled;logging=$item.logging}
        if (@($item.services).Count -gt 0) { $ruleObj | Add-Member -NotePropertyName simulatorServices -NotePropertyValue @($item.services) }
        $rules+= $ruleObj
    }
    $reservations=@()
    foreach ($item in @($Documents['manualIpReservations'].items)) {
        $id='urn:vcloud:networkManualIpReservation:'+(New-SimulatorGuid $Gateway.gatewayId 'manualIpReservations' $item.key)
        if ($item.key -match '^vcd-([0-9a-fA-F-]{36})$') { $id='urn:vcloud:networkManualIpReservation:'+$Matches[1] }
        $description=if ($null -ne $item.PSObject.Properties['description']) { [string]$item.description } else { '' }
        $reservations+= [pscustomobject]@{id=$id;name=$item.key;description=$description;networkRef=[pscustomobject]@{id=$item.networkId};ipAddresses=$item.address}
    }
    $Gateway.ipSets=@($groups)
    $Gateway.firewall.userDefinedRules=@($rules)
    $Gateway.reservations=@($reservations)
}

function Initialize-SimulatorWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,[string]$PersistencePath='')
    $workspace=@{}
    foreach ($gateway in @($Dataset.gateways)) {
        $workspace[[string]$gateway.gatewayId]=[pscustomobject]@{revision=0;documents=(ConvertFrom-SimulatorGateway -Gateway $gateway);flows=@()}
    }
    if ($PersistencePath -and [IO.File]::Exists($PersistencePath)) {
        $stored=Get-Content -LiteralPath $PersistencePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($stored.schemaVersion -ne 1 -or $stored.synthetic -ne $true -or @($stored.gateways).Count -ne 6) { throw 'Invalid simulator persistence data.' }
        foreach ($entry in @($stored.gateways)) {
            if (-not $workspace.ContainsKey([string]$entry.gatewayId) -or [int]$entry.revision -lt 0) { throw 'Unknown gateway or revision in simulator persistence.' }
            $docs=[ordered]@{}
            foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $docs[$kind]=$entry.documents.$kind }
            $null=Test-NetworkStateView -Documents $docs
            $gateway=@($Dataset.gateways | Where-Object { $_.gatewayId -ceq $entry.gatewayId })[0]
            foreach ($reservation in @($docs['manualIpReservations'].items)) { if ($reservation.networkId -cne $gateway.networkId) { throw 'Saved reservation references wrong network.' } }
            $workspace[[string]$entry.gatewayId]=[pscustomobject]@{revision=[int]$entry.revision;documents=$docs;flows=@($entry.flows)}
            ConvertTo-SimulatorGateway -Gateway $gateway -Documents $docs
        }
    }
    $Dataset | Add-Member -NotePropertyName simulatorWorkspace -NotePropertyValue $workspace -Force
    $Dataset | Add-Member -NotePropertyName simulatorPersistencePath -NotePropertyValue $PersistencePath -Force
    return $Dataset
}

function Get-SimulatorWorkspaceState {
    param([Parameter(Mandatory)]$Dataset,[Parameter(Mandatory)][string]$GatewayId)
    if ($null -eq $Dataset.PSObject.Properties['simulatorWorkspace']) { $null=Initialize-SimulatorWorkspace -Dataset $Dataset }
    if (-not $Dataset.simulatorWorkspace.ContainsKey($GatewayId)) { throw 'Unknown synthetic gateway.' }
    $gateway=@($Dataset.gateways | Where-Object { $_.gatewayId -ceq $GatewayId })[0]
    $slot=$Dataset.simulatorWorkspace[$GatewayId]
    return [pscustomobject]@{synthetic=$true;gatewayId=$GatewayId;domain=$gateway.domain;tier=$gateway.tier;networkId=$gateway.networkId;revision=[int]$slot.revision;documents=(Copy-NetworkDocuments $slot.documents)}
}

function Get-SimulatorPlanDigest {
    param([Parameter(Mandatory)]$Plan)
    # The editor computes this in a worker runspace, while the simulator
    # independently recomputes it in another PowerShell process.  An ordinary
    # hashtable has no guaranteed enumeration order, so JSON generated from
    # [pscustomobject]@{...} must NOT be used as a hash protocol.
    #
    # Explicitly order EVERY JSON map in the approval envelope, including the
    # action fields and counts.  Rule contents are independently canonicalised
    # by the shared state model (including set-valued fields).
    $normalized=@()
    foreach ($action in @($Plan.actions)) {
        $before=if ($null -eq $action.Before) { '' } else { Get-NetworkCanonicalItem -Item $action.Before }
        $after=if ($null -eq $action.After) { '' } else { Get-NetworkCanonicalItem -Item $action.After }
        $normalized+= [ordered]@{
            kind=[string]$action.ResourceKind
            key=[string]$action.Key
            change=[string]$action.Change
            before=$before
            after=$after
            dependencies=@($action.DependsOn | Sort-Object)
        }
    }
    $counts=[ordered]@{
        Create=[int]$Plan.summary.Create
        Update=[int]$Plan.summary.Update
        Move=[int]$Plan.summary.Move
        Delete=[int]$Plan.summary.Delete
    }
    $approval=[ordered]@{
        actions=@($normalized)
        summary=$counts
        blocked=[bool]$Plan.blocked
    }
    $text=ConvertTo-Json -InputObject $approval -Depth 40 -Compress
    $hash=[System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

# Approval v2 is based on the exact reviewed desired state, the gateway and
# the observed baseline, not a JSON serialization of a plan created independently
# in separate PowerShell processes.  The server still builds/validates its own
# plan before any commit.  This protocol is for the LOCAL simulator only.
function Get-SimulatorWorkspaceDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents)
    $null=Test-NetworkStateView -Documents $Documents
    $kinds=@()
    foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) {
        # Resource arrays are keyed sets. Firewall ordering is already retained
        # in every rule's explicit 'order' property, so item array position must
        # not make approvals differ between JSON and WinForms/runspace objects.
        $items=@()
        foreach ($item in @($Documents[$kind].items | Sort-Object -Property @{Expression={ [string]$_.key }} -CaseSensitive)) {
            $items+= [string](Get-NetworkCanonicalItem -Item $item)
        }
        $kinds+= [ordered]@{
            kind=$kind
            schemaVersion=[int]$Documents[$kind].schemaVersion
            resourceKind=[string]$Documents[$kind].resourceKind
            items=@($items)
        }
    }
    $serialized=ConvertTo-Json -InputObject ([ordered]@{version=2;resources=@($kinds)}) -Depth 40 -Compress
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($serialized))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# Approval v3 freezes the *exact* desired JSON payload at review time.  The
# later WinForms -> runspace -> HTTP boundary sends this string unchanged;
# hashing the string avoids re-materialising JSON in a different runspace.
# This is simulator-only, not a cryptographic signature or live change approval.
function Get-SimulatorFrozenPayloadDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Json)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Json))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-SimulatorApprovalDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GatewayId,
          [Parameter(Mandatory)][ValidateRange(0,2147483647)][int]$ExpectedRevision,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$BaselineDigest,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$DesiredDigest,
          [ValidateSet(2,3)][int]$Version=2)
    $envelope=[ordered]@{
        version=$Version
        gatewayId=$GatewayId
        expectedRevision=$ExpectedRevision
        baselineDigest=$BaselineDigest
        desiredDigest=$DesiredDigest
    }
    $serialized=ConvertTo-Json -InputObject $envelope -Depth 5 -Compress
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($serialized))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Save-SimulatorWorkspace {
    param([Parameter(Mandatory)]$Dataset,[Parameter(Mandatory)]$Workspace)
    $path=[string]$Dataset.simulatorPersistencePath
    if (-not $path) { return }
    $entries=@()
    foreach ($gateway in @($Dataset.gateways)) {
        $slot=$Workspace[[string]$gateway.gatewayId]
        $entries+= [pscustomobject]@{gatewayId=$gateway.gatewayId;revision=[int]$slot.revision;documents=$slot.documents;flows=@($slot.flows)}
    }
    $contents=ConvertTo-Json -InputObject ([pscustomobject]@{schemaVersion=1;synthetic=$true;gateways=$entries}) -Depth 50
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path))
    [void][IO.Directory]::CreateDirectory($directory)
    $temp="$path.$([guid]::NewGuid().ToString('n')).tmp"
    $backup="$path.$([guid]::NewGuid().ToString('n')).bak"
    try {
        [IO.File]::WriteAllText($temp,$contents,[System.Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,$backup); if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } }
        else { [IO.File]::Move($temp,$path) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Invoke-SimulatorApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,[Parameter(Mandatory)]$Request)
    if ($Request.confirmation -cne 'APPLY SIMULATOR') { throw 'Explicit simulator apply confirmation required.' }
    $current=Get-SimulatorWorkspaceState -Dataset $Dataset -GatewayId ([string]$Request.gatewayId)
    if ([int]$Request.expectedRevision -ne $current.revision) { throw '409: Simulator state changed; refresh and re-plan.' }
    $actor=[string]$Request.actorDomain; $actorTier=[int]$Request.actorTier
    $permission=Get-SimulatorAccessDecision -Dataset $Dataset -SourceDomain $actor -SourceTier $actorTier -TargetDomain $current.domain -TargetTier ([int]$current.tier)
    if (-not $permission.canManage) { throw '403: Synthetic domain/tier management policy denies the change.' }
    $role=Get-SimulatorActorRole -Dataset $Dataset -ActorDomain $actor -ActorTier $actorTier -TargetDomain $current.domain -TargetTier ([int]$current.tier)
    if (-not (Test-SimulatorRolePermission -Role $role.Role -Operation Apply)) { throw '403: Synthetic role lacks permission to apply; Tier 0 administrator required.' }
    # v2 is retained for compatibility with existing local simulator clients.
    # v3 binds approval to one frozen JSON string, sent unchanged from review
    # to apply.  No second, ambiguous 'documents' value is accepted in v3.
    $approvalVersion=if ($null -ne $Request.PSObject.Properties['approvalVersion']) { [int]$Request.approvalVersion } else { 0 }
    if ($approvalVersion -notin @(2,3)) { throw '409: Simulator approval format changed; generate a fresh plan.' }
    $docs=[ordered]@{}
    if ($approvalVersion -eq 3) {
        if ($null -ne $Request.PSObject.Properties['documents']) { throw '409: Ambiguous simulator desired state; generate a fresh plan.' }
        if ($null -eq $Request.PSObject.Properties['documentsJson'] -or $Request.documentsJson -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Request.documentsJson) -or $Request.documentsJson.Length -gt 8388608) {
            throw '409: Invalid frozen simulator draft; generate a fresh plan.'
        }
        # Integrity check is performed on the *raw submitted JSON string*, not
        # on its separate PowerShell object re-serialization.
        $submittedPayloadDigest=Get-SimulatorFrozenPayloadDigest -Json $Request.documentsJson
        if ([string]$Request.desiredDigest -cne $submittedPayloadDigest) {
            throw '409: Submitted simulator draft differs from the approved draft; generate a fresh plan.'
        }
        try { $incoming=ConvertFrom-Json -InputObject $Request.documentsJson -ErrorAction Stop }
        catch { throw '409: Frozen simulator draft is invalid JSON; generate a fresh plan.' }
        if ($incoming -isnot [pscustomobject]) { throw '409: Frozen simulator draft is not an object.' }
        foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) {
            if ($null -eq $incoming.PSObject.Properties[$kind]) { throw "Missing desired $kind document." }
            $docs[$kind]=$incoming.$kind
        }
        if (@($incoming.PSObject.Properties.Name).Count -ne 3) { throw '409: Unexpected simulator document types.' }
    }
    else {
        if ($null -eq $Request.PSObject.Properties['documents']) { throw 'Missing simulator desired documents.' }
        foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) {
            if ($null -eq $Request.documents.PSObject.Properties[$kind]) { throw "Missing desired $kind document." }
            $docs[$kind]=$Request.documents.$kind
        }
    }
    $null=Test-NetworkStateView -Documents $docs
    foreach ($item in @($docs['manualIpReservations'].items)) { if ($item.networkId -cne $current.networkId) { throw 'Reservation is outside the selected gateway network.' } }
    if (@($docs['edgeFirewallRules'].items).Count -gt 128 -or @($docs['ipSets'].items).Count -gt 128) { throw 'Simulator resource safety limit exceeded.' }
    $plan=New-SimulatorDocumentPlan -DesiredDocuments $docs -CurrentDocuments $current.documents -Scope $current.gatewayId
    if ($plan.blocked) { throw 'Plan blocked due to state drift or unsafe changes.' }
    # Refuse old plan-object-based approvals; they are not reliably reproducible
    # across the GUI/worker/HTTP boundary. Explicitly bind this decision to
    # both server baseline and approved desired-state contents.
    $actualBaseline=Get-SimulatorWorkspaceDigest -Documents $current.documents
    if ([string]$Request.baselineDigest -cne $actualBaseline) {
        throw '409: Simulator baseline differs from the approved snapshot; refresh and re-plan.'
    }
    if ($approvalVersion -eq 2) {
        $actualDesired=Get-SimulatorWorkspaceDigest -Documents $docs
        if ([string]$Request.desiredDigest -cne $actualDesired) {
            throw '409: Submitted simulator draft differs from the approved draft; generate a fresh plan.'
        }
    }
    else { $actualDesired=$submittedPayloadDigest }
    $actualApproval=Get-SimulatorApprovalDigest -GatewayId $current.gatewayId -ExpectedRevision $current.revision -BaselineDigest $actualBaseline -DesiredDigest $actualDesired -Version $approvalVersion
    if ([string]$Request.planDigest -cne $actualApproval) {
        throw '409: Simulator approval does not match the gateway, revision or reviewed draft.'
    }
    $updated=Copy-NetworkDocuments $docs
    $newWorkspace=@{}
    foreach ($key in @($Dataset.simulatorWorkspace.Keys)) { $newWorkspace[$key]=$Dataset.simulatorWorkspace[$key] }
    $newWorkspace[$current.gatewayId]=[pscustomobject]@{revision=($current.revision+1);documents=$updated;flows=@($Dataset.simulatorWorkspace[$current.gatewayId].flows)}
    # Disk commit happens before swapping in-memory pointers. Failed disk writes leave state unchanged.
    Save-SimulatorWorkspace -Dataset $Dataset -Workspace $newWorkspace
    $Dataset.simulatorWorkspace=$newWorkspace
    $gateway=@($Dataset.gateways | Where-Object { $_.gatewayId -ceq $current.gatewayId })[0]
    ConvertTo-SimulatorGateway -Gateway $gateway -Documents $updated
    return [pscustomobject]@{synthetic=$true;applied=$true;gatewayId=$current.gatewayId;revision=($current.revision+1);summary=$plan.summary}
}

function Invoke-SimulatorTraffic {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dataset,[Parameter(Mandatory)]$Request)
    $current=Get-SimulatorWorkspaceState -Dataset $Dataset -GatewayId ([string]$Request.gatewayId)
    $flow=Test-SimulatorFlow -Documents $current.documents -SourceIp ([string]$Request.sourceIp) -DestinationIp ([string]$Request.destinationIp) -Protocol ([string]$Request.protocol) -DestinationPort ([int]$Request.destinationPort)
    $entry=[pscustomobject]@{id=[guid]::NewGuid().ToString('n');timestampUtc=[DateTime]::UtcNow.ToString('o');gatewayId=$current.gatewayId;sourceIp=[string]$Request.sourceIp;destinationIp=[string]$Request.destinationIp;protocol=[string]$Request.protocol;destinationPort=[int]$Request.destinationPort;verdict=$flow.verdict;action=$flow.action;matchedRuleKey=$flow.matchedRuleKey;matchedRuleName=$flow.matchedRuleName;synthetic=$true}
    $slot=$Dataset.simulatorWorkspace[$current.gatewayId]
    $slot.flows=@(@($slot.flows) + @($entry) | Select-Object -Last 200)
    Save-SimulatorWorkspace -Dataset $Dataset -Workspace $Dataset.simulatorWorkspace
    return $entry
}

Export-ModuleMember -Function Initialize-SimulatorWorkspace, Get-SimulatorWorkspaceState, Get-SimulatorPlanDigest, Get-SimulatorWorkspaceDigest, Get-SimulatorFrozenPayloadDigest, Get-SimulatorApprovalDigest, Invoke-SimulatorApply, Invoke-SimulatorTraffic

# VCD 10.6 read-only policy representation (v3). Pure domain code: no transport or disk.
# v2 desired/applied/observed resource documents remain unchanged.
Set-StrictMode -Version Latest

$script:PolicySchemaVersion = 3
$script:KnownFirewallProperties = @(
    'id','name','description','sourceFirewallGroups','sourceFirewallIpAddresses',
    'destinationFirewallGroups','destinationFirewallIpAddresses','applicationPortProfiles',
    'rawPortProtocols','ipProtocol','actionValue','direction','logging','networkContextProfiles',
    'active','enabled','version','comments','appliedTo','loggingId','relativePosition'
)

function Get-VcdPolicyMember {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,($Object[$Name]) }
        return $null
    }
    if ($Object.PSObject.Properties.Name -ccontains $Name) { return ,($Object.$Name) }
    return $null
}

function Test-VcdPolicyMember {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return ($Object.PSObject.Properties.Name -ccontains $Name)
}

function Get-VcdPolicyArray {
    param($Value, [string]$Context = 'Collection')
    if ($null -eq $Value) { return ,@() }
    if ($Value -isnot [array]) { throw "$Context must be a JSON array." }
    return ,@($Value)
}

function ConvertTo-VcdPolicyCanonicalNode {
    param($Value)
    if ($null -eq $Value) { return $null }
    # PowerShell can expose ETS properties (for example, a string's Length)
    # through PSObject. Test scalar types *before* checking PSCustomObject,
    # otherwise an unknown property name can become {"Length":17} when
    # canonicalising a policy, corrupting a supposedly lossless round-trip.
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        # ConvertFrom-Json can promote ISO timestamps to DateTime in Windows
        # PowerShell 5.1. Normalise the string equivalent to the same instant.
        if ($Value -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') {
            $date = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                return $date.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
        return [string]$Value
    }
    if ($Value -is [array]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $Value) { $items.Add((ConvertTo-VcdPolicyCanonicalNode -Value $entry)) }
        # Arrays are intentionally NOT sorted: firewall rule order is semantic.
        return ,($items.ToArray())
    }
    if ($Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $names = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        $sorted = [ordered]@{}
        foreach ($name in @($names | Sort-Object -CaseSensitive)) {
            $member = Get-VcdPolicyMember -Object $Value -Name ([string]$name)
            $sorted[[string]$name] = ConvertTo-VcdPolicyCanonicalNode -Value $member
        }
        return $sorted
    }
    return $Value
}

function Get-VcdPolicyCanonicalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [switch]$SourceOnly)
    $null = Confirm-VcdPolicyDocument -Document $Document
    $value = if ($SourceOnly) { $Document.sourceSnapshot } else { $Document }
    $canonical = ConvertTo-VcdPolicyCanonicalNode -Value $value
    return (ConvertTo-Json -InputObject $canonical -Depth 100 -Compress)
}

function Get-VcdPolicyFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)
    # CapturedUtc is not included; identical effective source responses hash alike.
    $null = Confirm-VcdPolicyDocument -Document $Document
    $snapshot = $Document.sourceSnapshot
    $content = [ordered]@{
        gatewayId = $Document.gatewayId
        networkIds = @($Document.networkIds)
        firewall = $snapshot.firewall
        firewallGroupSummaries = $snapshot.firewallGroupSummaries
        ipSetDetails = $snapshot.ipSetDetails
        manualIpReservations = $snapshot.manualIpReservations
    }
    $canonical = ConvertTo-Json -InputObject (ConvertTo-VcdPolicyCanonicalNode $content) -Depth 100 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant())
    }
    finally { $sha.Dispose() }
}

function ConvertTo-VcdPolicyGroupReferences {
    param($References, [System.Collections.IDictionary]$Index, [string]$Context)
    $refs = Get-VcdPolicyArray -Value $References -Context $Context
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($reference in $refs) {
        $id = [string](Get-VcdPolicyMember $reference 'id')
        if ([string]::IsNullOrWhiteSpace($id)) { throw "$Context contains a reference without an ID." }
        $resolved = $Index.Contains($id)
        $group = if ($resolved) { $Index[$id] } else { $null }
        $out.Add([pscustomobject]@{
            id=$id
            name=[string](Get-VcdPolicyMember $reference 'name')
            typeValue=$(if ($resolved) { [string]$group.typeValue } else { '' })
            resolved=[bool]$resolved
            membershipResolved=$(if ($resolved) { [bool]$group.membershipResolved } else { $false })
        })
    }
    return ,($out.ToArray())
}

function ConvertTo-VcdPolicyDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    if (-not (Test-VcdPolicyMember $Snapshot 'firewall') -or $null -eq $Snapshot.firewall) { throw 'VCD snapshot has no firewall.' }
    $source = $Snapshot.firewall
    $gatewayId = [string](Get-VcdPolicyMember $Snapshot 'gatewayId')
    if (-not $gatewayId.StartsWith('urn:vcloud:')) { throw 'Policy snapshot requires a gateway URN.' }
    foreach ($section in @('systemRules','userDefinedRules','defaultRules')) {
        if (-not (Test-VcdPolicyMember $source $section)) { throw "Firewall response is missing '$section'." }
        $null = Get-VcdPolicyArray -Value (Get-VcdPolicyMember $source $section) -Context $section
    }
    $status = [string](Get-VcdPolicyMember $source 'status')
    if ([string]::IsNullOrWhiteSpace($status)) { throw 'Firewall response has no status.' }
    $summaryArray = Get-VcdPolicyArray (Get-VcdPolicyMember $Snapshot 'firewallGroupSummaries') 'Firewall group summaries'
    $detailArray = Get-VcdPolicyArray (Get-VcdPolicyMember $Snapshot 'ipSetDetails') 'IP Set details'
    $reservationArray = Get-VcdPolicyArray (Get-VcdPolicyMember $Snapshot 'manualIpReservations') 'IP reservations'
    $networks = Get-VcdPolicyArray (Get-VcdPolicyMember $Snapshot 'networkIds') 'Network IDs'

    $detailsById = @{}
    foreach ($detail in $detailArray) {
        $id = [string](Get-VcdPolicyMember $detail 'id')
        if ([string]::IsNullOrWhiteSpace($id) -or $detailsById.ContainsKey($id)) { throw 'Duplicate or missing IP Set detail ID.' }
        $detailsById[$id] = $detail
    }
    $groups = [System.Collections.Generic.List[object]]::new()
    $groupIndex = @{}
    foreach ($summary in $summaryArray) {
        $id = [string](Get-VcdPolicyMember $summary 'id')
        if ([string]::IsNullOrWhiteSpace($id) -or $groupIndex.ContainsKey($id)) { throw 'Duplicate or missing Firewall Group summary ID.' }
        $type = [string](Get-VcdPolicyMember $summary 'typeValue')
        $detail = if ($detailsById.ContainsKey($id)) { $detailsById[$id] } else { $null }
        if ($null -ne $detail -and ([string](Get-VcdPolicyMember $detail 'typeValue') -cne $type -or $type -cne 'IP_SET')) {
            throw "Firewall Group detail/summary mismatch for '$id'."
        }
        $addresses = @()
        $membershipResolved = $false
        if ($type -ceq 'IP_SET' -and $null -ne $detail -and (Test-VcdPolicyMember $detail 'ipAddresses')) {
            $rawAddresses = Get-VcdPolicyMember $detail 'ipAddresses'
            if ($rawAddresses -is [array]) {
                $addresses = Get-VcdPolicyArray $rawAddresses "IP Set '$id' addresses"
                $membershipResolved = $true
            }
        }
        $group = [pscustomobject]@{
            id=$id; name=[string](Get-VcdPolicyMember $summary 'name')
            typeValue=$type; addresses=@($addresses)
            membershipResolved=[bool]$membershipResolved
            rawSummary=$summary; rawDetail=$detail
        }
        $groups.Add($group)
        $groupIndex[$id] = $group
    }
    foreach ($id in @($detailsById.Keys)) {
        if (-not $groupIndex.ContainsKey($id)) { throw "IP Set detail '$id' has no summary in the same gateway." }
    }

    $sections = [ordered]@{}
    $identities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($section in @('systemRules','userDefinedRules','defaultRules')) {
        $normalized = [System.Collections.Generic.List[object]]::new()
        $position = 0
        foreach ($rule in (Get-VcdPolicyArray (Get-VcdPolicyMember $source $section) $section)) {
            $id = [string](Get-VcdPolicyMember $rule 'id')
            if ([string]::IsNullOrWhiteSpace($id) -or -not $identities.Add($id)) { throw 'Duplicate or missing firewall rule ID.' }
            $sourceRefs = ConvertTo-VcdPolicyGroupReferences -References (Get-VcdPolicyMember $rule 'sourceFirewallGroups') -Index $groupIndex -Context 'Source groups'
            $destRefs = ConvertTo-VcdPolicyGroupReferences -References (Get-VcdPolicyMember $rule 'destinationFirewallGroups') -Index $groupIndex -Context 'Destination groups'
            $extra = [string[]]@($rule.PSObject.Properties.Name | Where-Object { $_ -cnotin $script:KnownFirewallProperties })
            $reasons = [System.Collections.Generic.List[string]]::new()
            if ($section -cne 'userDefinedRules') { $reasons.Add('Protected system/default rule.') }
            if ($status -cne 'REALIZED') { $reasons.Add('Firewall is not REALIZED.') }
            if ($extra.Count -gt 0) { $reasons.Add(('Unknown VCD fields: ' + ($extra -join ', '))) }
            $enabled = Get-VcdPolicyMember $rule 'enabled'
            $active = Get-VcdPolicyMember $rule 'active'
            if ((Test-VcdPolicyMember $rule 'enabled') -and (Test-VcdPolicyMember $rule 'active') -and $enabled -is [bool] -and $active -is [bool] -and $enabled -ne $active) {
                $reasons.Add('Conflicting enabled/active values.')
            }
            if (($enabled -isnot [bool]) -and ($active -isnot [bool])) { $reasons.Add('No supported boolean enabled/active state.') }
            if ($section -ceq 'userDefinedRules' -and $active -isnot [bool]) { $reasons.Add('Legacy v2 projection requires an active boolean; enabled-only rules stay read-only.') }
            if (Test-VcdPolicyMember $rule 'enabled') { $reasons.Add('Legacy v2 cannot preserve the explicit enabled property.') }
            if (Get-VcdPolicyMember $rule 'comments') { $reasons.Add('Legacy v2 cannot preserve rule comments.') }
            foreach ($metadata in @('version','relativePosition','loggingId')) {
                if ($null -ne (Get-VcdPolicyMember $rule $metadata)) { $reasons.Add("Legacy v2 does not preserve '$metadata' metadata.") }
            }
            if ($null -ne $enabled -and $enabled -isnot [bool]) { $reasons.Add('Non-boolean enabled flag.') }
            if ($null -ne $active -and $active -isnot [bool]) { $reasons.Add('Non-boolean active flag.') }
            if ((Get-VcdPolicyMember $rule 'logging') -isnot [bool]) { $reasons.Add('Non-boolean logging flag.') }
            if ([string](Get-VcdPolicyMember $rule 'actionValue') -cnotin @('ALLOW','DROP','REJECT')) { $reasons.Add('Unmodelled firewall action.') }
            foreach ($feature in @('applicationPortProfiles','rawPortProtocols','sourceFirewallIpAddresses','destinationFirewallIpAddresses','networkContextProfiles')) {
                $values = Get-VcdPolicyMember $rule $feature
                if ($null -ne $values) {
                    $arr = Get-VcdPolicyArray $values $feature
                    if ($arr.Count -gt 0) { $reasons.Add("Requires advanced '$feature' representation.") }
                }
            }
            foreach ($feature in @('direction','appliedTo','ipProtocol')) {
                if ($null -ne (Get-VcdPolicyMember $rule $feature)) { $reasons.Add("Requires '$feature' semantics.") }
            }
            foreach ($ref in @($sourceRefs) + @($destRefs)) {
                if (-not $ref.membershipResolved -or $ref.typeValue -cne 'IP_SET') { $reasons.Add("Unresolved or dynamic firewall group '$($ref.id)'.") }
                elseif ($groupIndex[$ref.id].addresses.Count -eq 0) { $reasons.Add("Empty IP Set '$($ref.id)' cannot be projected to v2.") }
            }
            # Only supported legacy projections can be supplied to the existing v2 editor;
            # live edits and deployment are not implemented by this representation.
            $canProject = ($section -ceq 'userDefinedRules' -and $reasons.Count -eq 0)
            $normalized.Add([pscustomobject]@{
                id=$id; name=[string](Get-VcdPolicyMember $rule 'name')
                section=$section; position=$position
                enabled=$(if ($enabled -is [bool]) { $enabled } elseif ($active -is [bool]) { $active } else { $null })
                action=[string](Get-VcdPolicyMember $rule 'actionValue')
                logging=Get-VcdPolicyMember $rule 'logging'
                sourceGroups=@($sourceRefs); destinationGroups=@($destRefs)
                sourceAddresses=@((Get-VcdPolicyArray (Get-VcdPolicyMember $rule 'sourceFirewallIpAddresses') 'Source addresses'))
                destinationAddresses=@((Get-VcdPolicyArray (Get-VcdPolicyMember $rule 'destinationFirewallIpAddresses') 'Destination addresses'))
                applicationPortProfiles=@((Get-VcdPolicyArray (Get-VcdPolicyMember $rule 'applicationPortProfiles') 'Application profiles'))
                rawPortProtocols=@((Get-VcdPolicyArray (Get-VcdPolicyMember $rule 'rawPortProtocols') 'Raw protocols'))
                networkContextProfiles=@((Get-VcdPolicyArray (Get-VcdPolicyMember $rule 'networkContextProfiles') 'Network profiles'))
                unknownFields=[string[]]$extra
                raw=$rule
                capabilities=[pscustomobject]@{
                    CanInspect=$true; CanProjectToV2=[bool]$canProject
                    CanEdit=$false; CanPlan=$false; CanApply=$false
                    Reasons=@($reasons.ToArray())
                }
            })
            $position++
        }
        $sections[$section] = @($normalized.ToArray())
    }
    $document = [pscustomobject]@{
        schemaVersion=$script:PolicySchemaVersion
        documentType='VcdEdgeFirewallPolicy'
        apiVersion='39.0'
        gatewayId=$gatewayId
        capturedUtc=[string](Get-VcdPolicyMember $Snapshot 'capturedUtc')
        networkIds=@($networks)
        status=$status
        sections=[pscustomobject]$sections
        firewallGroups=@($groups.ToArray())
        manualIpReservations=@($reservationArray)
        sourceSnapshot=$Snapshot
    }
    $null = Confirm-VcdPolicyDocument -Document $document
    return $document
}

function Confirm-VcdPolicyDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)
    if ($null -eq $Document -or $Document -isnot [pscustomobject]) { throw 'VCD policy must be an object.' }
    foreach ($required in @('schemaVersion','documentType','apiVersion','gatewayId','networkIds','status','sections','firewallGroups','manualIpReservations','sourceSnapshot')) {
        if (-not (Test-VcdPolicyMember $Document $required) -or $null -eq (Get-VcdPolicyMember $Document $required)) { throw "VCD policy is missing '$required'." }
    }
    if (($Document.schemaVersion -isnot [int] -and $Document.schemaVersion -isnot [long]) -or [int]$Document.schemaVersion -ne 3) { throw 'Unsupported VCD policy schema. No automatic migration is permitted.' }
    if ($Document.documentType -cne 'VcdEdgeFirewallPolicy' -or $Document.apiVersion -cne '39.0') { throw 'Unsupported VCD policy type or API version.' }
    if ([string]::IsNullOrWhiteSpace([string]$Document.gatewayId) -or $Document.networkIds -isnot [array] -or $Document.firewallGroups -isnot [array] -or $Document.manualIpReservations -isnot [array]) { throw 'Malformed VCD policy scope or collections.' }
    $raw = $Document.sourceSnapshot
    if ([string](Get-VcdPolicyMember $raw 'gatewayId') -cne [string]$Document.gatewayId) { throw 'Policy gateway does not match raw source.' }
    $firewall = Get-VcdPolicyMember $raw 'firewall'
    if ([string](Get-VcdPolicyMember $firewall 'status') -cne [string]$Document.status) { throw 'Policy firewall status does not match raw source.' }
    foreach ($section in @('systemRules','userDefinedRules','defaultRules')) {
        $items = Get-VcdPolicyMember $Document.sections $section
        $rawItems = Get-VcdPolicyMember $firewall $section
        if ($items -isnot [array] -or $rawItems -isnot [array] -or $items.Count -ne $rawItems.Count) { throw "Invalid '$section' rule section." }
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i]
            if ([string]$item.id -cne [string](Get-VcdPolicyMember $rawItems[$i] 'id') -or $item.position -ne $i -or $item.section -cne $section) {
                throw "Rule identity or order changed in '$section'."
            }
            if ($null -eq $item.raw -or $null -eq $item.capabilities -or $item.capabilities.CanApply -ne $false -or $item.capabilities.CanEdit -ne $false) { throw 'Untrusted VCD policy capabilities.' }
        }
    }
    $rawGroups = Get-VcdPolicyArray (Get-VcdPolicyMember $raw 'firewallGroupSummaries')
    $rawReservations = Get-VcdPolicyArray (Get-VcdPolicyMember $raw 'manualIpReservations')
    if ($Document.firewallGroups.Count -ne $rawGroups.Count) { throw 'Group summary count does not match raw source.' }
    if ($Document.manualIpReservations.Count -ne $rawReservations.Count) { throw 'Reservation count does not match raw source.' }
    return $true
}

Export-ModuleMember -Function ConvertTo-VcdPolicyDocument, Confirm-VcdPolicyDocument, Get-VcdPolicyCanonicalJson, Get-VcdPolicyFingerprint

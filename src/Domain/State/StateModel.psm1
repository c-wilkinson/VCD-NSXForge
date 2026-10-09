# Pure state contracts. No filesystem, WinForms or HTTP dependencies.
Set-StrictMode -Version Latest

$script:ResourceKinds = @('ipSets','edgeFirewallRules','manualIpReservations')
$script:SchemaVersion = 2

function Get-NetworkResourceKinds { return @($script:ResourceKinds) }

function New-EmptyNetworkDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('ipSets','edgeFirewallRules','manualIpReservations')][string]$ResourceKind)
    return [pscustomobject]@{ schemaVersion = 2; resourceKind = $ResourceKind; items = @() }
}

function Test-NetworkIpAddress {
    param([string]$Address, [switch]$AllowCidr)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $segments = $Address.Split('/')
    if ($segments.Length -gt 2 -or ($segments.Length -gt 1 -and -not $AllowCidr)) { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($segments[0], [ref]$parsed)) { return $false }
    if ($segments.Length -eq 2) {
        if ($segments[1] -notmatch '^(0|[1-9][0-9]?)$') { return $false }
        $prefix = [int]$segments[1]
        $max = if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
        if ($prefix -gt $max) { return $false }
    }
    return $true
}

function Confirm-NetworkProperties {
    param($Item, [string[]]$Required, [string[]]$Optional, [string]$Context)
    if ($null -eq $Item -or $Item -isnot [pscustomobject]) { throw "$Context must be a JSON object." }
    $names = @($Item.PSObject.Properties.Name)
    foreach ($field in $Required) {
        if ($names -cnotcontains $field -or $null -eq $Item.$field) { throw "$Context is missing required field '$field'." }
    }
    foreach ($name in $names) {
        if (@($Required + $Optional) -cnotcontains $name) { throw "$Context contains unsupported field '$name'." }
    }
}

function Confirm-NetworkStringList {
    param($Values, [string]$Context, [switch]$AllowEmpty)
    if ($null -eq $Values -or $Values -isnot [array]) { throw "$Context must be a JSON array." }
    if (-not $AllowEmpty -and $Values.Count -eq 0) { throw "$Context cannot be empty." }
    $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Values) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw "$Context contains a blank or non-string value." }
        if (-not $unique.Add($value)) { throw "$Context contains duplicate '$value'." }
    }
}

function Confirm-NetworkDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)
    Confirm-NetworkProperties -Item $Document -Required @('schemaVersion','resourceKind','items') -Optional @() -Context 'State document'
    if (($Document.schemaVersion -isnot [int] -and $Document.schemaVersion -isnot [long]) -or [int]$Document.schemaVersion -ne $script:SchemaVersion) { throw 'Unsupported state document schema version.' }
    $kind = [string]$Document.resourceKind
    if ($kind -cnotin $script:ResourceKinds) { throw "Unsupported resource kind '$kind'." }
    if ($Document.items -isnot [array]) { throw "Items for '$kind' must be an array." }
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $orders = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($item in @($Document.items)) {
        $context = "$kind item"
        if ($kind -eq 'ipSets') {
            Confirm-NetworkProperties $item @('key','name','addresses') @('description') $context
        }
        elseif ($kind -eq 'edgeFirewallRules') {
            Confirm-NetworkProperties $item @('key','name','order','action','enabled','logging','sourceIpSets','destinationIpSets','services') @('description') $context
        }
        else {
            Confirm-NetworkProperties $item @('key','networkId','address') @('description') $context
        }
        if ($item.key -isnot [string] -or $item.key -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$') { throw "$context has invalid logical key." }
        if (-not $keys.Add([string]$item.key)) { throw "Duplicate '$kind' logical key '$($item.key)'." }
        if ($kind -eq 'ipSets') {
            if ($item.name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.name)) { throw 'IP Set name is required.' }
            Confirm-NetworkStringList -Values $item.addresses -Context "IP Set $($item.key) addresses"
            foreach ($address in $item.addresses) {
                if (-not (Test-NetworkIpAddress -Address $address -AllowCidr)) { throw "Invalid IP Set address '$address'." }
            }
        }
        elseif ($kind -eq 'edgeFirewallRules') {
            if ($item.name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.name)) { throw 'Firewall rule name is required.' }
            if (($item.order -isnot [int] -and $item.order -isnot [long]) -or $item.order -lt 0) { throw "Firewall rule $($item.key) requires a non-negative integer order." }
            if (-not $orders.Add([int]$item.order)) { throw "Duplicate firewall rule order '$($item.order)'." }
            if ($item.action -cnotin @('ALLOW','DROP','REJECT')) { throw "Firewall rule $($item.key) has unsupported action." }
            if ($item.enabled -isnot [bool] -or $item.logging -isnot [bool]) { throw "Firewall rule $($item.key) requires boolean enabled and logging." }
            Confirm-NetworkStringList -Values $item.sourceIpSets -Context "Rule $($item.key) sources" -AllowEmpty
            Confirm-NetworkStringList -Values $item.destinationIpSets -Context "Rule $($item.key) destinations" -AllowEmpty
            if ($item.services -isnot [array]) { throw "Firewall rule $($item.key) services must be an array." }
            foreach ($service in $item.services) {
                Confirm-NetworkProperties $service @('protocol','ports') @() "Rule $($item.key) service"
                if ($service.protocol -cnotin @('TCP','UDP','ICMP','ANY')) { throw "Unsupported protocol in rule $($item.key)." }
                Confirm-NetworkStringList -Values $service.ports -Context "Rule $($item.key) ports" -AllowEmpty
                if ($service.protocol -in @('TCP','UDP')) {
                    foreach ($port in $service.ports) {
                        if ($port -notmatch '^([0-9]{1,5})(-([0-9]{1,5}))?$') { throw "Invalid port '$port'." }
                        $start = [int]$Matches[1]
                        $end = if ($Matches[3]) { [int]$Matches[3] } else { $start }
                        if ($start -lt 1 -or $end -gt 65535 -or $end -lt $start) { throw "Invalid port '$port'." }
                    }
                }
                elseif ($service.ports.Count -ne 0) { throw 'ICMP and ANY services cannot specify TCP/UDP ports.' }
            }
        }
        else {
            if ($item.networkId -isnot [string] -or [string]::IsNullOrWhiteSpace($item.networkId)) { throw 'Reservation networkId is required.' }
            if ($item.address -isnot [string] -or -not (Test-NetworkIpAddress $item.address)) { throw "Invalid reserved IP '$($item.address)'." }
        }
        if (@($item.PSObject.Properties.Name) -ccontains 'description' -and $item.description -isnot [string]) { throw "Description for '$($item.key)' must be a string." }
    }
}

function ConvertTo-NetworkStateDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InputObject)
    if ($null -eq $InputObject -or $InputObject -isnot [pscustomobject]) { throw 'State file must contain a JSON object.' }
    if ($InputObject.PSObject.Properties.Name -cnotcontains 'schemaVersion') { throw 'State schemaVersion is required.' }
    $version = $InputObject.schemaVersion
    if ($version -isnot [int] -and $version -isnot [long]) { throw 'schemaVersion must be an integer.' }
    if ($version -eq 1) {
        Confirm-NetworkProperties $InputObject @('schemaVersion','resourceKind','resources') @() 'Legacy state document'
        $InputObject = [pscustomobject]@{ schemaVersion = 2; resourceKind = $InputObject.resourceKind; items = $InputObject.resources }
    }
    elseif ($version -ne 2) { throw "Unsupported state schema version '$version'." }
    Confirm-NetworkDocument -Document $InputObject
    return $InputObject
}

# Serialise recursively with sorted keys. Lists with set semantics are sorted;
# firewall order remains an explicit property and is never silently reordered.
function ConvertTo-NetworkCanonicalNode {
    param($Value, [string]$PropertyName = '')
    if ($null -eq $Value) { return $null }
    if ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary]) {
        $names = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        $sorted = [ordered]@{}
        foreach ($name in @($names | Sort-Object -CaseSensitive)) {
            $member = if ($Value -is [System.Collections.IDictionary]) { $Value[$name] } else { $Value.$name }
            $sorted[$name] = ConvertTo-NetworkCanonicalNode -Value $member -PropertyName $name
        }
        return $sorted
    }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-NetworkCanonicalNode -Value $_ })
        if ($PropertyName -in @('addresses','sourceIpSets','destinationIpSets','ports','services')) {
            $items = @($items | Sort-Object { ConvertTo-Json -InputObject $_ -Depth 30 -Compress })
        }
        return ,$items
    }
    return $Value
}

function Get-NetworkCanonicalItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item, [switch]$IgnoreOrder)
    $normalized = ConvertTo-NetworkCanonicalNode -Value $Item
    if ($IgnoreOrder -and $normalized.Contains('order')) { $normalized.Remove('order') }
    return (ConvertTo-Json -InputObject $normalized -Depth 30 -Compress)
}

Export-ModuleMember -Function Get-NetworkResourceKinds, New-EmptyNetworkDocument, Test-NetworkIpAddress, Confirm-NetworkDocument, ConvertTo-NetworkStateDocument, Get-NetworkCanonicalItem

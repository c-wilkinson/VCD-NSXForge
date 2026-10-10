# Pure translation of network-engineer form fields into the versioned state schema.
# No WinForms, filesystem, simulator or HTTP dependencies.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\StateModel.psm1') -ErrorAction Stop

function ConvertTo-NetworkEditorEntries {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,@() }
    $entries = @($Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    return ,$entries
}

function ConvertTo-NetworkEditorKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $key = $Name.Trim().ToLowerInvariant() -replace '[^a-z0-9_.-]+','-'
    $key = $key.Trim([char[]]@('-','_','.'))
    if ($key.Length -gt 80) { $key = $key.Substring(0,80).TrimEnd([char[]]@('-','_','.')) }
    if (-not $key) { throw 'Enter a descriptive name using letters or numbers.' }
    return $key
}

function ConvertTo-NetworkEditorItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('edgeFirewallRules','ipSets','manualIpReservations')][string]$ResourceKind,
        [Parameter(Mandatory)][hashtable]$Fields
    )
    $key = [string]$Fields.Key
    if ([string]::IsNullOrWhiteSpace($key)) {
        if ($ResourceKind -eq 'manualIpReservations') { $key = ConvertTo-NetworkEditorKey -Name ('reservation-'+[string]$Fields.Address) }
        else { $key = ConvertTo-NetworkEditorKey -Name ([string]$Fields.Name) }
    }
    $description = [string]$Fields.Description
    if ($ResourceKind -eq 'ipSets') {
        $item = [pscustomobject]@{
            key=$key;name=([string]$Fields.Name).Trim();description=$description
            addresses=[string[]](ConvertTo-NetworkEditorEntries -Text ([string]$Fields.Addresses))
        }
    }
    elseif ($ResourceKind -eq 'manualIpReservations') {
        $item = [pscustomobject]@{
            key=$key; networkId=([string]$Fields.NetworkId).Trim()
            address=([string]$Fields.Address).Trim();description=$description
        }
    }
    else {
        $services = @()
        foreach ($service in @($Fields.Services)) {
            if ($null -eq $service) { continue }
            $protocol = ([string]$service.Protocol).Trim().ToUpperInvariant()
            $ports = [string[]](ConvertTo-NetworkEditorEntries -Text ([string]$service.Ports))
            if ([string]::IsNullOrWhiteSpace($protocol)) { throw 'Each service requires a protocol.' }
            $services += [pscustomobject]@{protocol=$protocol;ports=$ports}
        }
        $item = [pscustomobject]@{
            key=$key;name=([string]$Fields.Name).Trim();description=$description
            order=[int]$Fields.Order;action=[string]$Fields.Action
            enabled=[bool]$Fields.Enabled;logging=[bool]$Fields.Logging
            sourceIpSets=[string[]]@($Fields.Sources)
            destinationIpSets=[string[]]@($Fields.Destinations)
            services=[object[]]$services
        }
    }
    $document = [pscustomobject]@{schemaVersion=2;resourceKind=$ResourceKind;items=[object[]]@($item)}
    Confirm-NetworkDocument -Document $document
    return $item
}

Export-ModuleMember -Function ConvertTo-NetworkEditorEntries, ConvertTo-NetworkEditorKey, ConvertTo-NetworkEditorItem

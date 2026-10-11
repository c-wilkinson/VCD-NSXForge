# Formats read-only VCD operation results for the dashboard and worker queue.
# A connection-only response is intentionally smaller than a full snapshot.
Set-StrictMode -Version Latest

function New-VcdReadCompletionSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [switch]$ConnectionOnly
    )

    if (-not $Result.Connected) { throw 'VCD read did not confirm a successful connection.' }
    if (-not $Result.ApiVersion) { throw 'VCD API version is missing from the result.' }

    $identitySuffix = if ($Result.PSObject.Properties.Name -contains 'IdentityLabel' -and $Result.IdentityLabel) { ' as ' + [string]$Result.IdentityLabel } else { '' }
    if ($ConnectionOnly) {
        return [pscustomobject]@{
            Message         = ('Connected successfully{0} - VCD API {1} (connection only; no snapshot created)' -f $identitySuffix,$Result.ApiVersion)
            ProgressMessage = 'VCD API connection verified'
            LogMessage      = 'VCD API connection verified (no snapshot created)'
        }
    }

    # Snapshot results have a different shape and must report all counts.
    foreach ($property in @('SnapshotPath','FirewallRuleCount','IpSetCount','ReservationCount')) {
        if ($Result.PSObject.Properties.Name -cnotcontains $property) {
            throw ("VCD snapshot is missing required property: {0}" -f $property)
        }
    }
    return [pscustomobject]@{
        Message         = ('VCD snapshot saved{0}: {1}; firewall rules={2}; IP Sets={3}; reservations={4}' -f $identitySuffix,$Result.SnapshotPath,$Result.FirewallRuleCount,$Result.IpSetCount,$Result.ReservationCount)
        ProgressMessage = 'Read-only VCD API snapshot complete'
        LogMessage      = 'Read-only VCD snapshot completed'
    }
}

Export-ModuleMember -Function New-VcdReadCompletionSummary

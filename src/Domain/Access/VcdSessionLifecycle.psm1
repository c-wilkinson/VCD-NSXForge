# Read-only VCD session lifecycle policy. This module owns no credentials or HTTP.
Set-StrictMode -Version Latest

function Get-VcdSessionLifecycleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Valid','Expiring','Expired','Revoked/Forbidden','RenewalUnavailable','ReauthenticationRequired')][string]$Status,
        [Nullable[datetime]]$ExpiresUtc = $null,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [ValidateRange(0,3600)][int]$ClockSkewSeconds = 60
    )
    $known = $null -ne $ExpiresUtc
    $effective = $Status
    if ($Status -in @('Valid','Expiring','Expired') -and $known) {
        $utc = ([datetime]$ExpiresUtc).ToUniversalTime()
        if ($NowUtc.ToUniversalTime() -ge $utc) { $effective = 'Expired' }
        elseif ($NowUtc.ToUniversalTime().AddSeconds($ClockSkewSeconds) -ge $utc) { $effective = 'Expiring' }
        else { $effective = 'Valid' }
    }
    return [pscustomobject]@{
        Status = $effective
        ExpiryKnown = [bool]$known
        ExpiresUtc = $(if ($known) { ([datetime]$ExpiresUtc).ToUniversalTime() } else { $null })
        CanUseToken = $effective -eq 'Valid'
        RequiresOperator = $effective -in @('Expired','Revoked/Forbidden','RenewalUnavailable','ReauthenticationRequired')
    }
}

function Get-VcdVerifiedSessionExpiry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    # Only documented, explicit session expiry timestamps are meaningful. Do not
    # infer bearer lifetime from login HTTP cache headers or assume JWT format.
    foreach ($property in @('expirationDate','expiresAt','expirationTime')) {
        $value = $null
        if ($Session -is [System.Collections.IDictionary]) {
            if ($Session.Contains($property)) { $value = $Session[$property] }
        }
        elseif ($null -ne $Session.PSObject.Properties[$property]) { $value = $Session.$property }
        if ($null -eq $value) { continue }
        # Windows PowerShell 5.1 ConvertFrom-Json can materialise ISO strings
        # as DateTime. Preserve their timezone semantics instead of applying
        # the current workstation's locale to a formatted string.
        if ($value -is [datetimeoffset]) { return $value.UtcDateTime }
        if ($value -is [datetime]) {
            if ($value.Kind -eq [System.DateTimeKind]::Unspecified) {
                throw 'VCD session expiry metadata has no explicit timezone.'
            }
            return $value.ToUniversalTime()
        }
        $stamp = [string]$value
        if ($stamp -notmatch '(?:Z|[+-][0-9]{2}:[0-9]{2})$') {
            throw 'VCD session expiry metadata has no explicit timezone.'
        }
        $parsed = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($stamp, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            throw 'VCD session expiry metadata is invalid.'
        }
        return $parsed.UtcDateTime
    }
    return $null
}

function Confirm-VcdRenewedSessionIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Original, [Parameter(Mandatory)]$Renewed)
    # Session ID necessarily changes. All identity and authorisation scope claims
    # must remain identical; matching username alone is never sufficient.
    foreach ($key in @('User','SessionOrgId','TargetOrgId','LoginScope','IsProvider')) {
        if ($null -eq $Original.PSObject.Properties[$key] -or $null -eq $Renewed.PSObject.Properties[$key] -or
            $Original.$key -cne $Renewed.$key) {
            throw 'VCD identity denied: renewed session identity or tenant scope changed.'
        }
    }
}

Export-ModuleMember -Function Get-VcdSessionLifecycleState, Get-VcdVerifiedSessionExpiry, Confirm-VcdRenewedSessionIdentity

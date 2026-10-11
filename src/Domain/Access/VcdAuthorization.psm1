# Live VMware Cloud Director authorisation. Never use simulator RBAC as a live grant.
# The session and resource ownership evidence must come from authenticated VCD GETs.
Set-StrictMode -Version Latest

function Get-VcdAccessValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-VcdOrgReference {
    param([Parameter(Mandatory)]$Object)
    foreach ($property in @('organizationRef','orgRef','ownerOrgRef','organization','org')) {
        $ref = Get-VcdAccessValue $Object $property
        if ($null -eq $ref) { continue }
        if ($ref -is [string] -and $ref -match '^urn:vcloud:org:') { return $ref }
        $id = Get-VcdAccessValue $ref 'id'
        if ($id -is [string] -and $id -match '^urn:vcloud:org:') { return $id }
    }
    foreach ($property in @('organizationId','orgId')) {
        $id = Get-VcdAccessValue $Object $property
        if ($id -is [string] -and $id -match '^urn:vcloud:org:') { return $id }
    }
    return ''
}

function New-VcdLiveIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session,
          [ValidateSet('Tenant','Provider')][string]$LoginScope='Tenant',
          [string]$TenantContextOrgId='')
    $sessionId = Get-VcdAccessValue $Session 'id'
    if ($sessionId -isnot [string] -or $sessionId -notmatch '^urn:vcloud:session:') {
        throw 'VCD identity denied: no valid authenticated session ID.'
    }
    $orgId = Get-VcdOrgReference $Session
    if (-not $orgId) { throw 'VCD identity denied: current session does not expose a verified organisation URN.' }
    $user = Get-VcdAccessValue $Session 'user'
    if ($null -ne $user -and $user -isnot [string]) { $user = Get-VcdAccessValue $user 'name' }
    if ([string]::IsNullOrWhiteSpace([string]$user) -or [string]$user -cnotmatch '^[a-zA-Z0-9_.@\\ -]{1,128}$') { $user = 'Authenticated VCD user' }
    # No role is inferred from a username or a locally selected login endpoint.
    $providerClaim = Get-VcdAccessValue $Session 'isProvider'
    if ($LoginScope -eq 'Provider' -and $providerClaim -isnot [bool]) {
        throw 'VCD identity denied: provider capability is not explicitly attested by the session.'
    }
    if ($LoginScope -eq 'Provider' -and -not $providerClaim) {
        throw 'VCD identity denied: the session is not provider-authorised.'
    }
    if ($LoginScope -eq 'Tenant' -and $TenantContextOrgId -and $orgId -cne $TenantContextOrgId) {
        throw 'VCD identity denied: the tenant context does not match the authenticated organisation.'
    }
    if ($LoginScope -eq 'Provider' -and -not $TenantContextOrgId) {
        throw 'VCD identity denied: provider reads require an explicit tenant context.'
    }
    $targetOrgId = if ($TenantContextOrgId) { $TenantContextOrgId } else { $orgId }
    return [pscustomobject]@{
        User = [string]$user
        SessionId = [string]$sessionId
        SessionOrgId = [string]$orgId
        TargetOrgId = [string]$targetOrgId
        LoginScope = $LoginScope
        IsProvider = [bool]($LoginScope -eq 'Provider')
        # No bearer token, credential or password belongs in this object.
    }
}

function Confirm-VcdLiveAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity,
          [Parameter(Mandatory)][ValidateSet('Connect','Discover','Read','Plan','Approve','Apply')][string]$Action,
          [string]$ResourceId = '',
          $Resource = $null)
    if ($Action -in @('Approve','Apply')) {
        throw "VCD authorisation denied: live $Action is not available."
    }
    if ($null -eq $Identity -or -not $Identity.SessionId -or -not $Identity.TargetOrgId) {
        throw 'VCD authorisation denied: missing verified identity context.'
    }
    if ($Action -eq 'Connect') { return }
    if (-not $ResourceId -or $null -eq $Resource) {
        throw 'VCD authorisation denied: scoped operations require server-returned resource ownership evidence.'
    }
    $returnedId = Get-VcdAccessValue $Resource 'id'
    $resourceOrg = Get-VcdOrgReference $Resource
    if ($returnedId -isnot [string] -or $returnedId -cne $ResourceId -or
        -not $resourceOrg -or $resourceOrg -cne $Identity.TargetOrgId) {
        throw 'VCD authorisation denied: requested resource does not match verified tenant ownership.'
    }
}

function Confirm-VcdArtifactContainsNoSecrets {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 90 -Compress
    # Reject, do not strip, sensitive data: silent removal conflicts with lossless observation.
    if ($json -match '(?i)"(?:password|passwd|secret|accessToken|refreshToken|authorization|privateKey|apiKey|x-vmware-vcloud-access-token)"\s*:' -or
        $json -match '(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}') {
        throw 'VCD snapshot contains sensitive credential material and cannot be exported.'
    }
}

Export-ModuleMember -Function Get-VcdOrgReference, New-VcdLiveIdentity, Confirm-VcdLiveAuthorization, Confirm-VcdArtifactContainsNoSecrets

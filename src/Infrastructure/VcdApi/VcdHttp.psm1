# Windows PowerShell 5.1 /.NET Framework read-only HTTP adapter.
# Login POST is the only permitted POST; data requests are GET-only.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Access\VcdSessionLifecycle.psm1') -ErrorAction Stop

function New-VcdHttpTransport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri]$BaseUri,
          [ValidateRange(5,180)][int]$TimeoutSeconds = 30,
          [string]$TenantContextOrgId = '',
          [System.Net.Http.HttpMessageHandler]$Handler = $null,
          [switch]$AllowLoopbackHttp)
    $safeLoopback = ($AllowLoopbackHttp -and $BaseUri.Scheme -ceq 'http' -and $BaseUri.Host -ceq '127.0.0.1')
    if (-not $BaseUri.IsAbsoluteUri -or ($BaseUri.Scheme -cne 'https' -and -not $safeLoopback) -or
        $BaseUri.AbsolutePath -cne '/' -or $BaseUri.Query -or $BaseUri.Fragment -or $BaseUri.UserInfo) {
        throw 'VCD transport requires an HTTPS origin with no credentials or path.'
    }
    if ($TenantContextOrgId -and $TenantContextOrgId -cnotmatch '^urn:vcloud:org:[a-fA-F0-9-]{8,}$') {
        throw 'Tenant context must be a VCD organisation URN.'
    }
    if ($null -eq $Handler) {
        $Handler = [System.Net.Http.HttpClientHandler]::new()
        $Handler.AllowAutoRedirect = $false
        $Handler.UseCookies = $false
        if ($safeLoopback) { $Handler.UseProxy = $false }
    }
    # Leave platform certificate validation enabled. Do not use -SkipCertificateCheck.
    $http = [System.Net.Http.HttpClient]::new($Handler, $true)
    $http.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $state = @{ Http = $http; BaseUri = $BaseUri; Token = ''; Tenant = $TenantContextOrgId; AllowLoopbackHttp = [bool]$safeLoopback; Gate = [object]::new(); Status = 'ReauthenticationRequired'; ExpiresUtc = $null }
    # GetNewClosure creates its own dynamic scope. Capture the imported helper
    # explicitly rather than depending on indirect module export visibility.
    $lifecycleCheck = (Get-Command Get-VcdSessionLifecycleState -ErrorAction Stop).ScriptBlock
    $sender = {
        param($call)
        if ($call.Method -cne 'GET') { throw 'Only GET is permitted through the VCD read transport.' }
        $uri = [uri]$call.Uri
        if (($uri.Scheme -cne 'https' -and -not ($state.AllowLoopbackHttp -and $uri.Scheme -ceq 'http' -and $uri.Host -ceq '127.0.0.1')) -or
            $uri.GetLeftPart([System.UriPartial]::Authority) -cne $state.BaseUri.GetLeftPart([System.UriPartial]::Authority) -or
            -not ($uri.AbsolutePath.StartsWith('/api/') -or $uri.AbsolutePath.StartsWith('/cloudapi/'))) {
            throw 'VCD read request attempted to leave the configured API origin or path.'
        }
        $ct = if ($call.PSObject.Properties.Name -contains 'CancellationToken') { $call.CancellationToken } else { [System.Threading.CancellationToken]::None }
        $ct.ThrowIfCancellationRequested()
        # One transport owns one session. Serialise send/login/invalidation so a
        # concurrent caller cannot send a stale token while reauthentication runs.
        while (-not [System.Threading.Monitor]::TryEnter($state.Gate, 100)) { $ct.ThrowIfCancellationRequested() }
        try {
        $health = & $lifecycleCheck -Status $state.Status -ExpiresUtc $state.ExpiresUtc
        if ($uri.AbsolutePath.StartsWith('/cloudapi/') -and -not $state.Token) {
            throw 'VCD read denied: no active authenticated session token.'
        }
        if ($uri.AbsolutePath.StartsWith('/cloudapi/') -and -not $health.CanUseToken) {
            throw 'VCD session unavailable; reauthentication required.'
        }
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
        try {
            foreach ($key in $call.Headers.Keys) {
                if ([string]$key -cne 'Accept' -or [string]$call.Headers[$key] -notmatch '^application/(json;version=[0-9]+\.[0-9]+|\*\+xml)$') {
                    throw 'VCD request rejected: only a version-pinned Accept header may be supplied.'
                }
                [void]$req.Headers.TryAddWithoutValidation('Accept', [string]$call.Headers[$key])
            }
            if ($state.Token) {
                $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $state.Token)
            }
            if ($state.Tenant) { [void]$req.Headers.TryAddWithoutValidation('X-VMWARE-VCLOUD-TENANT-CONTEXT', $state.Tenant) }
            $response = $state.Http.SendAsync($req, $ct).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) {
                    if ([int]$response.StatusCode -eq 401) { $state.Token = ''; $state.Status = 'ReauthenticationRequired'; $state.ExpiresUtc = $null }
                    if ([int]$response.StatusCode -eq 403) { $state.Token = ''; $state.Status = 'Revoked/Forbidden'; $state.ExpiresUtc = $null }
                    # Response bodies, reason phrases and server headers are untrusted.
                    throw "VCD GET failed: HTTP $([int]$response.StatusCode)."
                }
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($uri.AbsolutePath -eq '/api/versions') { return $body }
                if ([string]::IsNullOrWhiteSpace($body)) { throw 'VCD returned an empty JSON response.' }
                return (ConvertFrom-Json -InputObject $body -ErrorAction Stop)
            }
            finally { $response.Dispose() }
        }
        finally { $req.Dispose() }
        }
        finally { [System.Threading.Monitor]::Exit($state.Gate) }
    }.GetNewClosure()
    return [pscustomobject]@{ RequestSender = $sender; InternalState = $state }
}

function Connect-VcdHttpTransport {
    [CmdletBinding(DefaultParameterSetName='Credential')]
    param([Parameter(Mandatory)]$Transport,
          [Parameter(Mandatory,ParameterSetName='Credential')][pscredential]$Credential,
          [Parameter(Mandatory,ParameterSetName='BearerToken')][string]$BearerToken,
          [ValidatePattern('^\d+\.\d+$')][string]$ApiVersion = '39.0',
          [switch]$ProviderLogin,
          [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    $CancellationToken.ThrowIfCancellationRequested()
    # A failed reauthentication attempt must never retain a prior token.
    while (-not [System.Threading.Monitor]::TryEnter($Transport.InternalState.Gate, 100)) { $CancellationToken.ThrowIfCancellationRequested() }
    try {
    $Transport.InternalState.Token = ''
    $Transport.InternalState.Status = 'ReauthenticationRequired'
    $Transport.InternalState.ExpiresUtc = $null
    if ($PSCmdlet.ParameterSetName -eq 'BearerToken') {
        if ([string]::IsNullOrWhiteSpace($BearerToken)) { throw 'Bearer token must not be blank.' }
        if ($Transport.InternalState.AllowLoopbackHttp -and $BearerToken -cne 'simulator-read-only') {
            throw 'Only the built-in synthetic token is accepted by the loopback simulator transport.'
        }
        $Transport.InternalState.Token = $BearerToken
        $Transport.InternalState.Status = 'Valid'
        return
    }
    if ($Transport.InternalState.AllowLoopbackHttp) { throw 'Never send credentials over simulator HTTP. Use the synthetic bearer token.' }
    # This POST creates a VCD login session; it never changes network configuration.
    $loginPath = if ($ProviderLogin) { '/cloudapi/1.0.0/sessions/provider' } else { '/cloudapi/1.0.0/sessions' }
    $uri = [uri]::new($Transport.InternalState.BaseUri, $loginPath)
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
    try {
        $networkCredential = $Credential.GetNetworkCredential()
        $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($networkCredential.UserName + ':' + $networkCredential.Password))
        $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $basic)
        [void]$req.Headers.TryAddWithoutValidation('Accept', "application/json;version=$ApiVersion")
        $result = $Transport.InternalState.Http.SendAsync($req, $CancellationToken).GetAwaiter().GetResult()
        try {
            if (-not $result.IsSuccessStatusCode) { throw "VCD session login failed: HTTP $([int]$result.StatusCode)." }
            $tokenValues = $null
            if (-not $result.Headers.TryGetValues('X-VMWARE-VCLOUD-ACCESS-TOKEN', [ref]$tokenValues)) { throw 'VCD login response did not contain the access-token header.' }
            $token = @($tokenValues)[0]
            if ([string]::IsNullOrWhiteSpace($token)) { throw 'VCD login returned an empty token.' }
            $Transport.InternalState.Token = [string]$token
            $Transport.InternalState.Status = 'Valid'
        }
        finally { $result.Dispose() }
    }
    finally { $req.Dispose(); $basic = $null; $networkCredential = $null }
    }
    catch {
        $Transport.InternalState.Token = ''
        $Transport.InternalState.Status = 'RenewalUnavailable'
        throw
    }
    finally { [System.Threading.Monitor]::Exit($Transport.InternalState.Gate) }
}

function Set-VcdTransportSessionLifetime {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)]$Session)
    $expiry = Get-VcdVerifiedSessionExpiry -Session $Session
    [System.Threading.Monitor]::Enter($Transport.InternalState.Gate)
    try {
        if ($Transport.InternalState.Status -ne 'Valid') { throw 'VCD session unavailable; reauthentication required.' }
        $Transport.InternalState.ExpiresUtc = $expiry
    }
    finally { [System.Threading.Monitor]::Exit($Transport.InternalState.Gate) }
}

function Get-VcdTransportSessionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transport)
    [System.Threading.Monitor]::Enter($Transport.InternalState.Gate)
    try {
        return (Get-VcdSessionLifecycleState -Status $Transport.InternalState.Status -ExpiresUtc $Transport.InternalState.ExpiresUtc)
    }
    finally { [System.Threading.Monitor]::Exit($Transport.InternalState.Gate) }
}

function Close-VcdHttpTransport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transport)
    [System.Threading.Monitor]::Enter($Transport.InternalState.Gate)
    try {
        $Transport.InternalState.Token = ''
        $Transport.InternalState.Status = 'ReauthenticationRequired'
        $Transport.InternalState.ExpiresUtc = $null
        $Transport.InternalState.Http.Dispose()
    }
    finally { [System.Threading.Monitor]::Exit($Transport.InternalState.Gate) }
}

Export-ModuleMember -Function New-VcdHttpTransport, Connect-VcdHttpTransport, Close-VcdHttpTransport, Set-VcdTransportSessionLifetime, Get-VcdTransportSessionStatus

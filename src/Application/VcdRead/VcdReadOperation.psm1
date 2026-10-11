Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\VcdApi\VcdApi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\VcdApi\VcdHttp.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VcdSnapshot.psm1') -Force
# Explicit imports are required: a dependency imported privately by VcdSnapshot
# is not automatically exported into this module's command resolution scope.
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\VcdPolicyModel.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\State\VcdPolicyRepository.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Access\VcdAuthorization.psm1') -ErrorAction Stop

function Invoke-VcdReadOperation {
    [CmdletBinding(DefaultParameterSetName='Credential')]
    param(
        [Parameter(Mandatory)]$VcdConfiguration,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(ParameterSetName='Credential')][pscredential]$Credential,
        [Parameter(ParameterSetName='Token')][string]$BearerToken,
        [scriptblock]$RequestSender,
        [switch]$WriteObserved,
        [switch]$WritePolicyObserved,
        [string]$StateRoot,
        [string]$Environment,
        [string]$Scope,
        [switch]$ConnectionOnly,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    if (-not $VcdConfiguration.apiUrl) { throw 'Set vcd.apiUrl in config/application.json before connecting.' }
    $simulatorMode = ($VcdConfiguration.PSObject.Properties.Name -contains 'mode' -and $VcdConfiguration.mode -ceq 'Simulator')
    if ($simulatorMode -and ($null -ne $Credential -or $PSBoundParameters.ContainsKey('BearerToken'))) {
        throw 'Do not supply real credentials or bearer tokens to the local simulator.'
    }
    if ($simulatorMode) {
        $simUri = [uri]$VcdConfiguration.apiUrl
        if ($simUri.Scheme -cne 'http' -or $simUri.Host -cne '127.0.0.1' -or $simUri.AbsolutePath -cne '/' -or $simUri.UserInfo -or $simUri.Query -or $simUri.Fragment) {
            throw 'Simulator must use an HTTP loopback origin at 127.0.0.1.'
        }
    }
    if (($WriteObserved -or $WritePolicyObserved) -and (-not $StateRoot -or -not $Environment -or -not $Scope)) { throw 'StateRoot, Environment and Scope are required for observed-state import.' }
    if (($WriteObserved -or $WritePolicyObserved) -and @($VcdConfiguration.networkIds).Count -eq 0) { throw 'Observed-state import requires one or more explicit network URNs; an unqueried reservation scope cannot be treated as empty.' }
    if ($ConnectionOnly -and ($WriteObserved -or $WritePolicyObserved)) { throw 'Connection-only cannot publish observed state.' }
    if (-not $ConnectionOnly -and (-not $VcdConfiguration.gatewayId)) { throw 'Set vcd.gatewayId to an Edge Gateway URN before retrieving a snapshot.' }
    $transport = $null
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        if ($null -eq $RequestSender) {
            $transport = New-VcdHttpTransport -BaseUri ([uri]$VcdConfiguration.apiUrl) -TimeoutSeconds ([int]$VcdConfiguration.timeoutSeconds) -TenantContextOrgId ([string]$VcdConfiguration.tenantContextOrgId) -AllowLoopbackHttp:$simulatorMode
            $RequestSender = $transport.RequestSender
        }
        $client = New-VcdApiClient -BaseUri ([uri]$VcdConfiguration.apiUrl) -RequestSender $RequestSender -ApiVersion ([string]$VcdConfiguration.apiVersion) -AllowLoopbackHttp:$simulatorMode
        # /api/versions is unauthenticated. Never downgrade or guess API versions.
        $versions = @(Get-VcdApiVersions -Client $client -CancellationToken $CancellationToken)
        if ($versions -notcontains [string]$VcdConfiguration.apiVersion) { throw "VCD server does not advertise required API version $($VcdConfiguration.apiVersion)." }
        $CancellationToken.ThrowIfCancellationRequested()
        if ($null -ne $transport) {
            if ($simulatorMode) {
                Connect-VcdHttpTransport -Transport $transport -BearerToken 'simulator-read-only' -ApiVersion ([string]$VcdConfiguration.apiVersion) -CancellationToken $CancellationToken
            }
            elseif ($PSCmdlet.ParameterSetName -eq 'Token') {
                Connect-VcdHttpTransport -Transport $transport -BearerToken $BearerToken -ApiVersion ([string]$VcdConfiguration.apiVersion) -CancellationToken $CancellationToken
            }
            elseif ($null -ne $Credential) {
                Connect-VcdHttpTransport -Transport $transport -Credential $Credential -ApiVersion ([string]$VcdConfiguration.apiVersion) -ProviderLogin ($VcdConfiguration.loginScope -eq 'Provider') -CancellationToken $CancellationToken
            }
            else { throw 'Provide a credential or bearer token at runtime; credentials are never read from JSON.' }
        }
        # Check actual authentication / tenant rights.
        $session = Invoke-VcdRead -Client $client -Path '/cloudapi/1.0.0/sessions/current' -CancellationToken $CancellationToken
        if ($null -eq $session -or -not $session.id) { throw 'VCD did not return a valid current session.' }
        $CancellationToken.ThrowIfCancellationRequested()
        # Live identity is derived exclusively from the authenticated session response.
        # Simulator policies are synthetic and are never treated as VCD grants.
        $identity = $null
        if (-not $simulatorMode) {
            $loginScope = if ($VcdConfiguration.PSObject.Properties.Name -contains 'loginScope' -and [string]$VcdConfiguration.loginScope) { [string]$VcdConfiguration.loginScope } else { 'Tenant' }
            $targetOrg = if ($VcdConfiguration.PSObject.Properties.Name -contains 'tenantContextOrgId') { [string]$VcdConfiguration.tenantContextOrgId } else { '' }
            $identity = New-VcdLiveIdentity -Session $session -LoginScope $loginScope -TenantContextOrgId $targetOrg
            Confirm-VcdLiveAuthorization -Identity $identity -Action Connect
        }
        $identityLabel = if ($null -ne $identity) { $identity.User + ' (' + $identity.TargetOrgId + ')' } else { 'Synthetic simulator identity' }
        if ($ConnectionOnly) { return [pscustomobject]@{ Connected=$true; ApiVersion=$client.ApiVersion; SnapshotPath=''; ObservedImported=$false; IdentityLabel=$identityLabel } }
        if (-not $simulatorMode) {
            # No firewall, network or observed-state read is allowed until its
            # ownership is proved by authenticated, server-returned metadata.
            $gateway = Get-VcdGatewayOwnership -Client $client -GatewayId ([string]$VcdConfiguration.gatewayId) -CancellationToken $CancellationToken
            Confirm-VcdLiveAuthorization -Identity $identity -Action Read -ResourceId ([string]$VcdConfiguration.gatewayId) -Resource $gateway
            foreach ($networkId in @($VcdConfiguration.networkIds)) {
                $CancellationToken.ThrowIfCancellationRequested()
                $network = Get-VcdNetworkOwnership -Client $client -NetworkId ([string]$networkId) -CancellationToken $CancellationToken
                Confirm-VcdLiveAuthorization -Identity $identity -Action Read -ResourceId ([string]$networkId) -Resource $network
            }
        }
        $snapshot = Get-VcdReadSnapshot -Client $client -GatewayId ([string]$VcdConfiguration.gatewayId) -NetworkIds @($VcdConfiguration.networkIds) -CancellationToken $CancellationToken
        $CancellationToken.ThrowIfCancellationRequested()
        Confirm-VcdArtifactContainsNoSecrets -Value $snapshot
        # Persist raw data first so unsupported mapping can be diagnosed offline.
        $rawPath = Save-VcdRawSnapshot -Snapshot $snapshot -OutputDirectory $OutputDirectory
        $policyPath = ''
        if ($WriteObserved -or $WritePolicyObserved) {
            # Commit the complete v3 observed policy independently of legacy v2.
            # An advanced policy can be inspected safely even when the v2 editor
            # cannot represent it. No desired/applied state is modified here.
            $policy = ConvertTo-VcdPolicyDocument -Snapshot $snapshot
            $CancellationToken.ThrowIfCancellationRequested()
            $policySave = Save-VcdPolicyObserved -Document $policy -StateRoot $StateRoot -Environment $Environment -Scope $Scope
            $policyPath = $policySave.Path
            if ($WriteObserved) {
                # Legacy v2 remains deliberately strict. On failure the old v2
                # observed directory is untouched; the v3 policy and raw snapshot
                # remain available for inspection and diagnosis.
                $docs = ConvertTo-VcdLegacyPolicyProjection -Policy $policy
                $CancellationToken.ThrowIfCancellationRequested()
                $null = Publish-VcdObservedView -Documents $docs -StateRoot $StateRoot -Environment $Environment -Scope $Scope
            }
        }
        return [pscustomobject]@{
            Connected = $true; ApiVersion = $client.ApiVersion; IdentityLabel = $identityLabel
            SnapshotPath = $rawPath; PolicyPath = $policyPath; PolicyImported = [bool]($WriteObserved -or $WritePolicyObserved); ObservedImported = [bool]$WriteObserved
            FirewallRuleCount = @($snapshot.firewall.userDefinedRules).Count
            IpSetCount = @($snapshot.ipSetDetails).Count
            ReservationCount = @($snapshot.manualIpReservations).Count
        }
    }
    catch [System.OperationCanceledException] { throw }
    catch {
        # Untrusted servers and injected senders can put arbitrary data into
        # exception text. Only narrowly recognised, generated messages escape.
        $failure = [string]$_.Exception.Message
        if ($failure -match '^VCD identity denied: [A-Za-z .-]+\.$' -or
            $failure -match '^VCD authorisation denied: [A-Za-z .-]+\.$' -or
            $failure -match '^VCD GET failed: HTTP [0-9]{3}\.$' -or
            $failure -match '^VCD session login failed: HTTP [0-9]{3}\.$') {
            throw $failure
        }
        throw 'VCD operation failed; check connectivity, identity, scope and policy support. Server details have been withheld.'
    }
    finally { if ($null -ne $transport) { Close-VcdHttpTransport -Transport $transport } }
}

Export-ModuleMember -Function Invoke-VcdReadOperation

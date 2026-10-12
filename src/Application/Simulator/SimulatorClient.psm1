# Simulator-only HTTP client. No production VCD request path or real credentials.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\Editing\NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Planning\Planning.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\Simulator\SimulatorWorkspace.psm1') -ErrorAction Stop

Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\Simulator\SimulatorHttp.psm1') -ErrorAction Stop

# Explicit wrappers keep the application API stable while HTTP remains Infrastructure-only.
function Confirm-SimulatorOrigin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiUrl)
    return SimulatorHttp\Confirm-SimulatorOrigin -ApiUrl $ApiUrl
}
function Invoke-SimulatorApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiUrl,
          [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
          [Parameter(Mandatory)][ValidateSet('scopes','state','apply','traffic')][string]$Resource,
          [string]$GatewayId='', $Payload,
          [System.Threading.CancellationToken]$CancellationToken=[System.Threading.CancellationToken]::None)
    return SimulatorHttp\Invoke-SimulatorApi @PSBoundParameters
}

function Get-SimulatorDraftPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Baseline,[Parameter(Mandatory)]$DesiredDocuments)
    # Freeze the reviewed draft into the exact wire-level JSON once.  The
    # simulator apply uses this immutable string instead of reserializing the
    # WinForms/runspace object later.  Plan over the *frozen representation* so
    # the operator reviews the very state that will be submitted.
    $frozenJson=ConvertTo-Json -InputObject $DesiredDocuments -Depth 40 -Compress
    if ($frozenJson.Length -gt 8388608) { throw 'Simulator draft exceeds the local approval size limit.' }
    $frozenObject=ConvertFrom-Json -InputObject $frozenJson -ErrorAction Stop
    $frozenDocuments=[ordered]@{}
    foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $frozenDocuments[$kind]=$frozenObject.$kind }
    $null=Test-NetworkStateView -Documents $frozenDocuments
    $plan=New-SimulatorDocumentPlan -DesiredDocuments $frozenDocuments -CurrentDocuments $Baseline.documents -Scope ([string]$Baseline.gatewayId)
    $baselineDigest=Get-SimulatorWorkspaceDigest -Documents $Baseline.documents
    $desiredDigest=Get-SimulatorWorkspaceDigest -Documents $DesiredDocuments
    $approvalDigest=Get-SimulatorApprovalDigest -GatewayId ([string]$Baseline.gatewayId) -ExpectedRevision ([int]$Baseline.revision) -BaselineDigest $baselineDigest -DesiredDigest $desiredDigest
    $frozenDesiredDigest=Get-SimulatorFrozenPayloadDigest -Json $frozenJson
    $frozenApprovalDigest=Get-SimulatorApprovalDigest -GatewayId ([string]$Baseline.gatewayId) -ExpectedRevision ([int]$Baseline.revision) -BaselineDigest $baselineDigest -DesiredDigest $frozenDesiredDigest -Version 3
    return [pscustomobject]@{
        plan=$plan
        approvalVersion=2
        planDigest=$approvalDigest
        baselineDigest=$baselineDigest
        desiredDigest=$desiredDigest
        expectedRevision=[int]$Baseline.revision
        documents=$DesiredDocuments # v2 legacy callers; never used by the v3 HTTP apply
        frozenDocumentsJson=$frozenJson
        frozenDesiredDigest=$frozenDesiredDigest
        frozenPlanDigest=$frozenApprovalDigest
    }
}

function New-SimulatorApprovedApplyRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Approved,
          [Parameter(Mandatory)][string]$ActorDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$ActorTier)
    if ($Approved.plan.blocked) { throw 'Blocked plan cannot be applied.' }
    # Fail closed on older approval objects; an old GUI worker cannot silently
    # fall back to an object-based hash once the v3 wire contract is expected.
    if ($null -eq $Approved.PSObject.Properties['frozenDocumentsJson'] -or
        $null -eq $Approved.PSObject.Properties['frozenDesiredDigest'] -or
        $null -eq $Approved.PSObject.Properties['frozenPlanDigest']) {
        throw 'Simulator approval must be regenerated with the current application version.'
    }
    if ((Get-SimulatorFrozenPayloadDigest -Json $Approved.frozenDocumentsJson) -cne $Approved.frozenDesiredDigest) {
        throw '409: Reviewed simulator draft was modified after approval; generate a fresh plan.'
    }
    $expected=Get-SimulatorApprovalDigest -GatewayId ([string]$Approved.plan.scope) -ExpectedRevision ([int]$Approved.expectedRevision) -BaselineDigest ([string]$Approved.baselineDigest) -DesiredDigest ([string]$Approved.frozenDesiredDigest) -Version 3
    if ($expected -cne $Approved.frozenPlanDigest) { throw '409: Simulator approval metadata changed; generate a fresh plan.' }
    $request=[pscustomobject]@{
        gatewayId=$Approved.plan.scope;expectedRevision=$Approved.expectedRevision
        approvalVersion=3;baselineDigest=$Approved.baselineDigest
        desiredDigest=$Approved.frozenDesiredDigest;planDigest=$Approved.frozenPlanDigest
        documentsJson=$Approved.frozenDocumentsJson
        actorDomain=$ActorDomain;actorTier=$ActorTier;confirmation='APPLY SIMULATOR'
    }
    return $request
}

function Invoke-SimulatorApprovedApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiUrl,[Parameter(Mandatory)]$Approved,
          [Parameter(Mandatory)][string]$ActorDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$ActorTier,
          [System.Threading.CancellationToken]$CancellationToken=[System.Threading.CancellationToken]::None)
    $CancellationToken.ThrowIfCancellationRequested()
    $request=New-SimulatorApprovedApplyRequest -Approved $Approved -ActorDomain $ActorDomain -ActorTier $ActorTier
    return Invoke-SimulatorApi -ApiUrl $ApiUrl -Method POST -Resource apply -Payload $request -CancellationToken $CancellationToken
}

Export-ModuleMember -Function Confirm-SimulatorOrigin, Invoke-SimulatorApi, Get-SimulatorDraftPlan, New-SimulatorApprovedApplyRequest, Invoke-SimulatorApprovedApply

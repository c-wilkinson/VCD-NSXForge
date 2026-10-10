# Simulator-only HTTP client. No production VCD request path or real credentials.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\Editing\NetworkEditing.psm1') -ErrorAction Stop
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
    $plan=New-SimulatorDocumentPlan -DesiredDocuments $DesiredDocuments -CurrentDocuments $Baseline.documents -Scope ([string]$Baseline.gatewayId)
    return [pscustomobject]@{ plan=$plan;planDigest=(Get-SimulatorPlanDigest -Plan $plan);expectedRevision=[int]$Baseline.revision;documents=$DesiredDocuments }
}

function Invoke-SimulatorApprovedApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiUrl,[Parameter(Mandatory)]$Approved,
          [Parameter(Mandatory)][string]$ActorDomain,
          [Parameter(Mandatory)][ValidateRange(0,1)][int]$ActorTier,
          [System.Threading.CancellationToken]$CancellationToken=[System.Threading.CancellationToken]::None)
    if ($Approved.plan.blocked) { throw 'Blocked plan cannot be applied.' }
    $request=[pscustomobject]@{gatewayId=$Approved.plan.scope;expectedRevision=$Approved.expectedRevision;planDigest=$Approved.planDigest;documents=$Approved.documents;actorDomain=$ActorDomain;actorTier=$ActorTier;confirmation='APPLY SIMULATOR'}
    return Invoke-SimulatorApi -ApiUrl $ApiUrl -Method POST -Resource apply -Payload $request -CancellationToken $CancellationToken
}

Export-ModuleMember -Function Confirm-SimulatorOrigin, Invoke-SimulatorApi, Get-SimulatorDraftPlan, Invoke-SimulatorApprovedApply

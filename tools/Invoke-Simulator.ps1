#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Scopes','State','Plan','Apply','Traffic','TrafficHistory')][string]$Action,
      [string]$GatewayId='',
      [string]$DesiredPath='',[string]$OutputPath='',
      [string]$SourceIp='',[string]$DestinationIp='',
      [ValidateSet('TCP','UDP','ICMP')][string]$Protocol='TCP',[int]$Port=443,
      [ValidateSet('DomainA','DomainB','DomainC')][string]$ActorDomain='DomainA',
      [ValidateRange(0,1)][int]$ActorTier=0,
      [switch]$ConfirmSimulatorApply,
      [string]$ApprovedPlanDigest='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'src\Application\Configuration\Configuration.psm1') -ErrorAction Stop
Import-Module (Join-Path $root 'src\Application\Simulator\SimulatorClient.psm1') -ErrorAction Stop
$config=Read-AppConfiguration -ApplicationRoot $root
if ($config.vcd.mode -cne 'Simulator') { throw 'The simulator CLI is disabled in Live mode. Use tools/Use-VcdSimulator.ps1 first.' }
$url=Confirm-SimulatorOrigin -ApiUrl ([string]$config.vcd.apiUrl)
if (-not $GatewayId) { $GatewayId=[string]$config.vcd.gatewayId }
switch ($Action) {
    'Scopes' { $result=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource scopes; break }
    'State' { $result=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource state -GatewayId $GatewayId; break }
    'TrafficHistory' { $result=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource traffic -GatewayId $GatewayId; break }
    'Traffic' {
        if (-not $SourceIp -or -not $DestinationIp) { throw 'Specify SourceIp and DestinationIp.' }
        $result=Invoke-SimulatorApi -ApiUrl $url -Method POST -Resource traffic -Payload ([pscustomobject]@{gatewayId=$GatewayId;sourceIp=$SourceIp;destinationIp=$DestinationIp;protocol=$Protocol;destinationPort=$Port})
        break
    }
    default {
        if (-not $DesiredPath -or -not [IO.File]::Exists($DesiredPath)) { throw 'Plan and Apply require -DesiredPath with a JSON file containing documents.ipSets, documents.edgeFirewallRules and documents.manualIpReservations.' }
        $desired=Get-Content -LiteralPath $DesiredPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $docs=[ordered]@{}
        foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) { $docs[$kind]=$desired.documents.$kind }
        $current=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource state -GatewayId $GatewayId
        $approved=Get-SimulatorDraftPlan -Baseline $current -DesiredDocuments $docs
        if ($Action -eq 'Plan') { $result=[pscustomobject]@{plan=$approved.plan;planDigest=$approved.planDigest;expectedRevision=$approved.expectedRevision} }
        else {
            if (-not $ConfirmSimulatorApply -or -not $ApprovedPlanDigest -or $ApprovedPlanDigest -cne $approved.planDigest) { throw 'Apply requires -ConfirmSimulatorApply and the matching -ApprovedPlanDigest from a reviewed Plan output.' }
            $result=Invoke-SimulatorApprovedApply -ApiUrl $url -Approved $approved -ActorDomain $ActorDomain -ActorTier $ActorTier
        }
    }
}
if ($OutputPath) {
    $text=ConvertTo-Json -InputObject $result -Depth 40
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$text,[System.Text.UTF8Encoding]::new($false))
    Write-Host "Synthetic $Action output written to $OutputPath"
}
else { $result | ConvertTo-Json -Depth 40 }

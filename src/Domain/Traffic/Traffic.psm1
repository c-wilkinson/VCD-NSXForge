# Synthetic deterministic first-match firewall evaluator; never claims to inspect actual packets.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\State\StateModel.psm1') -ErrorAction Stop

function Test-SimulatorIpMatch {
    param([string]$Address,[string]$Range)
    $ip=$null; $base=$null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$ip)) { return $false }
    $parts=$Range.Split('/')
    if (-not [Net.IPAddress]::TryParse($parts[0],[ref]$base) -or $ip.AddressFamily -ne $base.AddressFamily) { return $false }
    if ($parts.Count -eq 1) { return $ip.Equals($base) }
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^\d{1,3}$') { return $false }
    $bits=[int]$parts[1]; $a=$ip.GetAddressBytes(); $b=$base.GetAddressBytes()
    if ($bits -gt $a.Length*8) { return $false }
    for ($i=0; $i -lt $a.Length; $i++) {
        $maskBits=[Math]::Max(0,[Math]::Min(8,$bits-($i*8)))
        $mask=if ($maskBits -eq 0) { 0 } else { (256 - (1 -shl (8-$maskBits))) }
        if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { return $false }
    }
    return $true
}

function Test-SimulatorRuleAddress {
    param([string]$Address,[object[]]$SetKeys,$SetIndex)
    if (@($SetKeys).Count -eq 0) { return $true }
    foreach ($key in @($SetKeys)) {
        if (-not $SetIndex.ContainsKey([string]$key)) { return $false }
        foreach ($range in @($SetIndex[[string]$key].addresses)) {
            if (Test-SimulatorIpMatch -Address $Address -Range ([string]$range)) { return $true }
        }
    }
    return $false
}

function Test-SimulatorService {
    param([object[]]$Services,[string]$Protocol,[int]$Port)
    if (@($Services).Count -eq 0) { return $true }
    foreach ($svc in $Services) {
        if ($svc.protocol -eq 'ANY') { return $true }
        if ($svc.protocol -cne $Protocol) { continue }
        if ($Protocol -eq 'ICMP') { return $true }
        if (@($svc.ports).Count -eq 0) { return $true }
        foreach ($entry in @($svc.ports)) {
            $bounds=([string]$entry).Split('-')
            if ($Port -ge [int]$bounds[0] -and $Port -le [int]$bounds[$bounds.Length-1]) { return $true }
        }
    }
    return $false
}

function Test-SimulatorFlow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,
          [Parameter(Mandatory)][string]$SourceIp,
          [Parameter(Mandatory)][string]$DestinationIp,
          [Parameter(Mandatory)][ValidateSet('TCP','UDP','ICMP')][string]$Protocol,
          [ValidateRange(0,65535)][int]$DestinationPort=0)
    if (-not (Test-NetworkIpAddress $SourceIp) -or -not (Test-NetworkIpAddress $DestinationIp)) { throw 'A valid source and destination IP is required.' }
    if ($Protocol -in @('TCP','UDP') -and $DestinationPort -eq 0) { throw 'TCP and UDP require a destination port.' }
    $sets=@{}
    foreach ($set in @($Documents['ipSets'].items)) { $sets[[string]$set.key]=$set }
    foreach ($rule in @($Documents['edgeFirewallRules'].items | Sort-Object order)) {
        if (-not $rule.enabled) { continue }
        if (-not (Test-SimulatorRuleAddress -Address $SourceIp -SetKeys @($rule.sourceIpSets) -SetIndex $sets)) { continue }
        if (-not (Test-SimulatorRuleAddress -Address $DestinationIp -SetKeys @($rule.destinationIpSets) -SetIndex $sets)) { continue }
        if (-not (Test-SimulatorService -Services @($rule.services) -Protocol $Protocol -Port $DestinationPort)) { continue }
        return [pscustomobject]@{ verdict= $(if ($rule.action -eq 'ALLOW') {'Allowed'} else {'Denied'}); matchedRuleKey=$rule.key; matchedRuleName=$rule.name; action=$rule.action; synthetic=$true }
    }
    return [pscustomobject]@{ verdict='Denied'; matchedRuleKey=''; matchedRuleName='Default deny'; action='DROP'; synthetic=$true }
}
Export-ModuleMember -Function Test-SimulatorFlow, Test-SimulatorIpMatch

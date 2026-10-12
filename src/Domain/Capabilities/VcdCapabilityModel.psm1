# Issue #9: evidence-driven VCD capability catalogue. Pure, read-only domain logic.
Set-StrictMode -Version Latest

function Get-VcdCapabilityMember {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -ne $member) { return $member.Value }
    return $null
}

function Read-VcdCapabilityCatalogue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $data = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) -ErrorAction Stop
    $expected = @('catalogueSchemaVersion','catalogueId','toolCompatibility','testedVcdRelease','apiVersion',
        'gatewayMode','networkBacking','observedPolicySchemaVersion','supportedReads','policySections',
        'readFidelity','legacyV2Projection','liveWriteSupported','evidence','limitations')
    $actual = @($data.PSObject.Properties.Name)
    if (@($expected | Where-Object { $_ -cnotin $actual }).Count -gt 0 -or
        @($actual | Where-Object { $_ -cnotin $expected }).Count -gt 0) { throw 'Capability catalogue has missing or unknown properties.' }
    if (($data.catalogueSchemaVersion -isnot [int] -and $data.catalogueSchemaVersion -isnot [long]) -or [int]$data.catalogueSchemaVersion -ne 1 -or
        ($data.observedPolicySchemaVersion -isnot [int] -and $data.observedPolicySchemaVersion -isnot [long]) -or [int]$data.observedPolicySchemaVersion -ne 3 -or
        $data.liveWriteSupported -isnot [bool] -or $data.liveWriteSupported -or
        $data.supportedReads -isnot [array] -or $data.policySections -isnot [array] -or
        $data.evidence -isnot [array] -or $data.limitations -isnot [array] -or
        @($data.policySections).Count -ne 3 -or
        [string]::IsNullOrWhiteSpace([string]$data.catalogueId) -or
        [string]::IsNullOrWhiteSpace([string]$data.toolCompatibility) -or
        [string]::IsNullOrWhiteSpace([string]$data.testedVcdRelease) -or
        [string]::IsNullOrWhiteSpace([string]$data.apiVersion) -or
        [string]::IsNullOrWhiteSpace([string]$data.gatewayMode) -or
        [string]::IsNullOrWhiteSpace([string]$data.networkBacking) -or
        $data.readFidelity -cne 'lossless-raw-and-v3' -or
        $data.legacyV2Projection -cne 'validated-subset-only') { throw 'Unsupported or unsafe capability catalogue.' }
    return $data
}

function New-VcdCapabilityFinding {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)][string]$Explanation, [ValidateSet('Info','Partial','Unknown','Unsupported')][string]$Severity='Partial')
    [pscustomobject]@{ Code=$Code; Path=$Path; Severity=$Severity; Explanation=$Explanation }
}

function New-VcdUnknownCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GatewayId, [string]$Explanation='The gateway has not been assessed.')
    [pscustomobject]@{
        CapabilitySchemaVersion=1; CatalogueId=''; CatalogueSchemaVersion=0; PolicySchemaVersion=3
        GatewayId=$GatewayId; Verdict='Unknown'; ReadStatus='Unknown'; Complete=$false
        CanInspectRaw=$false; CanProjectToV2=$false; CanPlan=$false; CanApply=$false
        ApiVersion=''; VcdRelease=''; GatewayMode=''; NetworkBacking=''
        Findings=@((New-VcdCapabilityFinding -Code 'NOT_ASSESSED' -Path 'gateway' -Severity Unknown -Explanation $Explanation))
    }
}

Export-ModuleMember -Function Get-VcdCapabilityMember, Read-VcdCapabilityCatalogue, New-VcdCapabilityFinding, New-VcdUnknownCapability

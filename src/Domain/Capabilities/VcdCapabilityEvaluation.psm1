# Issue #9: pure assessment, independent of transport/UI/persistence.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'VcdCapabilityModel.psm1') -ErrorAction Stop

function Get-VcdCapabilityAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalogue, [Parameter(Mandatory)][string]$GatewayId,
          [Parameter(Mandatory)][string]$ApiVersion, $GatewayMetadata, $Policy,
          [bool]$VersionAdvertised=$false)
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = { param($code,$path,$message,$severity)
        $findings.Add((New-VcdCapabilityFinding -Code $code -Path $path -Explanation $message -Severity $severity))
    }
    $release=[string](Get-VcdCapabilityMember $GatewayMetadata 'vcdVersion')
    $mode=[string](Get-VcdCapabilityMember $GatewayMetadata 'gatewayMode')
    $backing=[string](Get-VcdCapabilityMember $GatewayMetadata 'networkBacking')
    $observedId=[string](Get-VcdCapabilityMember $GatewayMetadata 'id')
    $unsupported=$false; $unknown=$false; $partial=$false
    if (-not $VersionAdvertised -or $ApiVersion -cne [string]$Catalogue.apiVersion) {
        & $add 'API_UNVERIFIED' 'api.version' 'The server has not advertised the tested API version.' 'Unknown'; $unknown=$true
    }
    if ($GatewayMetadata -eq $null -or $observedId -cne $GatewayId) {
        & $add 'GATEWAY_UNVERIFIED' 'gateway.id' 'Gateway metadata is absent or refers to a different ID.' 'Unknown'; $unknown=$true
    }
    if ([string]::IsNullOrWhiteSpace($release)) {
        & $add 'RELEASE_UNKNOWN' 'gateway.vcdVersion' 'The VCD release/build is not server-attested; API version alone cannot establish compatibility.' 'Unknown'; $unknown=$true
    } elseif ($release -cne [string]$Catalogue.testedVcdRelease) {
        & $add 'RELEASE_UNTESTED' 'gateway.vcdVersion' 'The reported VCD release does not match this tested catalogue.' 'Unknown'; $unknown=$true
    }
    if ([string]::IsNullOrWhiteSpace($mode)) {
        & $add 'MODE_UNKNOWN' 'gateway.gatewayMode' 'Gateway firewall mode was not reported.' 'Unknown'; $unknown=$true
    } elseif ($mode -cne [string]$Catalogue.gatewayMode) {
        & $add 'MODE_UNSUPPORTED' 'gateway.gatewayMode' 'This gateway mode is not supported by this catalogue.' 'Unsupported'; $unsupported=$true
    }
    if ([string]::IsNullOrWhiteSpace($backing)) {
        & $add 'BACKING_UNKNOWN' 'gateway.networkBacking' 'Gateway NSX backing was not verified.' 'Unknown'; $unknown=$true
    } elseif ($backing -cne [string]$Catalogue.networkBacking) {
        & $add 'BACKING_UNSUPPORTED' 'gateway.networkBacking' 'This gateway backing type is incompatible with the tested NSX-T read model.' 'Unsupported'; $unsupported=$true
    }
    $projection = $false
    if ($null -eq $Policy) {
        & $add 'POLICY_NOT_INSPECTED' 'firewall' 'Complete firewall rules and referenced groups have not been assessed.' 'Unknown'
        $unknown=$true
    } else {
        if ([int]$Policy.schemaVersion -ne [int]$Catalogue.observedPolicySchemaVersion) {
            & $add 'POLICY_SCHEMA_INCOMPATIBLE' 'policy.schemaVersion' 'Observed policy schema is incompatible with the tested catalogue.' 'Unsupported'
            $unsupported=$true
        } elseif ([string]$Policy.gatewayId -cne $GatewayId) {
            & $add 'POLICY_GATEWAY_MISMATCH' 'policy.gatewayId' 'Observed policy belongs to a different gateway.' 'Unsupported'
            $unsupported=$true
        } elseif ([string]::IsNullOrWhiteSpace([string](Get-VcdCapabilityMember $Policy 'apiVersion'))) {
            & $add 'POLICY_API_MISSING' 'policy.apiVersion' 'Observed policy API version is missing; compatibility cannot be established.' 'Unknown'
            $unknown=$true
        } elseif ([string]$Policy.apiVersion -cne $ApiVersion) {
            if ($VersionAdvertised -and $ApiVersion -ceq [string]$Catalogue.apiVersion) {
                & $add 'POLICY_API_MISMATCH' 'policy.apiVersion' 'Observed policy API version conflicts with the verified, tested server API.' 'Unsupported'
                $unsupported=$true
            } else {
                & $add 'POLICY_API_UNVERIFIED' 'policy.apiVersion' 'Policy and requested API versions differ, but this API combination is not verified against the catalogue.' 'Unknown'
                $unknown=$true
            }
        } else {
            $projection=$true
            if ([string]$Policy.status -cne 'REALIZED') {
                & $add 'FIREWALL_STATE' 'firewall.status' 'Firewall is not in REALIZED state.' 'Partial'; $partial=$true; $projection=$false
            }
            # A new root firewall property may alter policy-wide semantics even if
            # every individual rule looks like the supported legacy subset.
            $rawFirewall=Get-VcdCapabilityMember $Policy.sourceSnapshot 'firewall'
            foreach ($name in @($rawFirewall.PSObject.Properties.Name)) {
                if ($name -cnotin @('status','systemRules','userDefinedRules','defaultRules')) {
                    & $add 'UNKNOWN_FIREWALL_PROPERTY' ('firewall.'+$name) 'New firewall-level API semantics are preserved raw; editable projection is not authorised.' 'Partial'
                    $partial=$true; $projection=$false
                }
            }
            foreach ($section in @('systemRules','userDefinedRules','defaultRules')) {
                $rules=@($Policy.sections.$section)
                if ($section -cne 'userDefinedRules' -and $rules.Count -gt 0) {
                    & $add 'PROTECTED_RULES' ('firewall.'+$section) 'Rules are preserved for inspection but cannot be represented in editable v2 state.' 'Partial'
                    $partial=$true; $projection=$false
                }
                for ($i=0;$i -lt $rules.Count;$i++) {
                    $rule=$rules[$i]; $prefix=('firewall.{0}[{1}]' -f $section,$i)
                    foreach ($field in @($rule.unknownFields)) {
                        & $add 'UNKNOWN_POLICY_FIELD' ($prefix+'.'+[string]$field) 'Unknown API field is preserved in the raw and v3 documents, not flattened.' 'Partial'
                        $partial=$true; $projection=$false
                    }
                    foreach ($field in @('applicationPortProfiles','rawPortProtocols','sourceFirewallIpAddresses','destinationFirewallIpAddresses','networkContextProfiles')) {
                        $value=Get-VcdCapabilityMember $rule.raw $field
                        if ($null -ne $value -and @($value).Count -gt 0) {
                            & $add 'ADVANCED_POLICY_FIELD' ($prefix+'.'+$field) 'Feature is retained read-only; legacy v2 projection cannot represent it faithfully.' 'Partial'
                            $partial=$true; $projection=$false
                        }
                    }
                    foreach ($field in @('direction','appliedTo','ipProtocol','comments','version','relativePosition','loggingId')) {
                        $value=Get-VcdCapabilityMember $rule.raw $field
                        if ($null -ne $value) {
                            & $add 'SCOPE_OR_METADATA' ($prefix+'.'+$field) 'Scope/metadata must be preserved; legacy v2 does not model this field.' 'Partial'
                            $partial=$true; $projection=$false
                        }
                    }
                    if (-not [bool]$rule.capabilities.CanProjectToV2) {
                        $projection=$false; $partial=$true
                        foreach ($reason in @($rule.capabilities.Reasons)) {
                            & $add 'V2_PROJECTION_BLOCKED' $prefix ([string]$reason) 'Partial'
                        }
                    }
                }
            }
            foreach ($group in @($Policy.firewallGroups)) {
                foreach ($source in @(@{Entry=$group.rawSummary;Known=@('id','name','description','typeValue','edgeGatewayRef')},
                                       @{Entry=$group.rawDetail;Known=@('id','name','description','typeValue','ipAddresses')})) {
                    if ($null -eq $source.Entry) { continue }
                    foreach ($field in @($source.Entry.PSObject.Properties.Name)) {
                        if ($field -cnotin $source.Known) {
                            & $add 'UNKNOWN_GROUP_FIELD' ('firewallGroups['+[string]$group.id+'].'+$field) 'Unknown firewall-group attributes are not flattened into an editable IP Set.' 'Partial'
                            $partial=$true; $projection=$false
                        }
                    }
                }
                if (-not [bool]$group.membershipResolved -or [string]$group.typeValue -cne 'IP_SET') {
                    & $add 'GROUP_MEMBERSHIP_UNKNOWN' ('firewallGroups['+[string]$group.id+']') 'Dynamic/unresolved group must never become an empty IP Set.' 'Partial'
                    $projection=$false; $partial=$true
                }
            }
            for ($i=0; $i -lt @($Policy.manualIpReservations).Count; $i++) {
                $reservation=@($Policy.manualIpReservations)[$i]
                $address=Get-VcdCapabilityMember $reservation 'ipAddresses'
                $network=Get-VcdCapabilityMember $reservation 'networkRef'
                $networkId=[string](Get-VcdCapabilityMember $network 'id')
                $unsupportedReservation=($address -isnot [string] -or [string]::IsNullOrWhiteSpace($address) -or
                    $address.Contains(',') -or $address.Contains('-') -or -not $networkId)
                foreach ($feature in @('expirationType','expirationDate','expirationVAppRef','allowIpUsageByServiceOrVm','removeIpAfterUsage')) {
                    if ($null -ne (Get-VcdCapabilityMember $reservation $feature)) {
                        & $add 'RESERVATION_LIFECYCLE' ('manualIpReservations['+$i+'].'+$feature) 'Reservation lifecycle semantics cannot be represented in v2.' 'Partial'
                        $unsupportedReservation=$true
                    }
                }
                if ($unsupportedReservation) {
                    & $add 'RESERVATION_SHAPE' ('manualIpReservations['+$i+'].ipAddresses') 'Reservation range, type or network reference cannot be verified for v2.' 'Partial'
                    $partial=$true; $projection=$false
                }
            }
            # The legacy converter still enforces exact IP validity, referential integrity
            # and downstream schema constraints before allowing any observed-state publication.
        }
    }
    $verdict=if ($unsupported) {'Unsupported'} elseif ($unknown) {'Unknown'} elseif ($partial) {'Partial'} else {'Supported (read)'}
    # All verdicts prohibit live writes. Unknown/unsupported assessments are never promoted.
    $read=if ($null -eq $Policy -or $unsupported) {'Unknown'} else {'Supported (read)'}
    [pscustomobject]@{
        CapabilitySchemaVersion=1; CatalogueId=[string]$Catalogue.catalogueId
        CatalogueSchemaVersion=[int]$Catalogue.catalogueSchemaVersion
        PolicySchemaVersion=[int]$Catalogue.observedPolicySchemaVersion
        GatewayId=$GatewayId; Verdict=$verdict; ReadStatus=$read
        Complete=($null -ne $Policy -and -not $unknown -and -not $unsupported)
        CanInspectRaw=($null -ne $Policy); CanProjectToV2=($projection -and -not $unknown -and -not $unsupported)
        CanPlan=$false; CanApply=$false
        ApiVersion=$ApiVersion; VcdRelease=$release; GatewayMode=$mode; NetworkBacking=$backing
        Findings=@($findings.ToArray())
    }
}

function Confirm-VcdCapabilityProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Assessment)
    if ($Assessment.Verdict -cne 'Supported (read)' -or -not $Assessment.CanProjectToV2 -or
        -not $Assessment.Complete -or $Assessment.CanApply) { throw 'VCD capability preflight does not authorise editable legacy projection.' }
    return $true
}

Export-ModuleMember -Function Get-VcdCapabilityAssessment, Confirm-VcdCapabilityProjection

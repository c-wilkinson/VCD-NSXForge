# Table-driven, offline capability fixtures; no VCD calls, writes or WinForms.
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\VcdPolicyModel.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Capabilities\VcdCapabilityEvaluation.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Capabilities\VcdCapabilityModel.psm1') -ErrorAction Stop
$capCatalogue=Read-VcdCapabilityCatalogue -Path (Join-Path $ProjectRoot 'config\capabilities\vcd-10.6-api-39.0.json')
$capGateway='urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
function New-CapGateway {
    return [pscustomobject]@{ id=$capGateway;vcdVersion='10.6';gatewayMode='NSXT_BACKED';networkBacking='NSX_T' }
}
function New-CapPolicy {
    $firewall=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $ProjectRoot 'tests\Fixtures\Vcd106\edge-firewall-rules.json')))
    $summaryA=(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $ProjectRoot 'tests\Fixtures\Vcd106\firewall-groups-page1.json')))).values[0]
    $summaryB=(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $ProjectRoot 'tests\Fixtures\Vcd106\firewall-groups-page2.json')))).values[0]
    $detail=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $ProjectRoot 'tests\Fixtures\Vcd106\firewall-group-ipset.json')))
    $snapshot=[pscustomobject]@{
        schemaVersion=1; gatewayId=$capGateway; networkIds=@(); capturedUtc='2026-10-12T08:00:00Z'
        firewall=$firewall;firewallGroupSummaries=@($summaryA,$summaryB)
        ipSetDetails=@($detail);manualIpReservations=@()
    }
    return ConvertTo-VcdPolicyDocument -Snapshot $snapshot
}

Invoke-TestCase -Name 'Catalogue pins VCD/API/gateway/schema evidence and prohibits live writes' -Body {
    Assert-Equal 1 $capCatalogue.catalogueSchemaVersion
    Assert-Equal '39.0' $capCatalogue.apiVersion
    Assert-Equal '10.6' $capCatalogue.testedVcdRelease
    Assert-Equal 3 $capCatalogue.observedPolicySchemaVersion
    Assert-True (-not $capCatalogue.liveWriteSupported)
    Assert-True (@($capCatalogue.evidence).Count -ge 2)
}
Invoke-TestCase -Name 'VCD 10.6 advanced fixture preserves sections and reports field-level limitations' -Body {
    $policy=New-CapPolicy
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway) -Policy $policy
    Assert-Equal 'Partial' $result.Verdict
    Assert-Equal 'Supported (read)' $result.ReadStatus
    Assert-True $result.Complete
    Assert-True $result.CanInspectRaw
    Assert-True (-not $result.CanProjectToV2)
    Assert-True (-not $result.CanApply)
    $paths=@($result.Findings | ForEach-Object { $_.Path })
    foreach ($name in @('applicationPortProfiles','destinationFirewallIpAddresses','appliedTo','defaultRules','systemRules','rawPortProtocols')) {
        Assert-True (@($paths | Where-Object { $_ -like ('*'+$name+'*') }).Count -gt 0) "Missing field path $name"
    }
    Assert-Throws { Confirm-VcdCapabilityProjection -Assessment $result }
}
Invoke-TestCase -Name 'Unknown future property produces a precise path and remains raw' -Body {
    $policy=New-CapPolicy
    $policy.sourceSnapshot.firewall.userDefinedRules[0] | Add-Member -NotePropertyName futureSetting -NotePropertyValue ([pscustomobject]@{extra=$null})
    $policy=ConvertTo-VcdPolicyDocument -Snapshot $policy.sourceSnapshot
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway) -Policy $policy
    Assert-True (@($result.Findings | Where-Object { $_.Path -eq 'firewall.userDefinedRules[0].futureSetting' }).Count -eq 1)
    Assert-True ($null -ne $policy.sourceSnapshot.firewall.userDefinedRules[0].futureSetting)
}
Invoke-TestCase -Name 'Expected complete simple firewall is supported for read only' -Body {
    $policy=New-CapPolicy
    $policy.sourceSnapshot.firewall.userDefinedRules=@()
    $policy.sourceSnapshot.firewall.defaultRules=@()
    $policy.sourceSnapshot.firewall.systemRules=@()
    $policy.sourceSnapshot.firewallGroupSummaries=@()
    $policy.sourceSnapshot.ipSetDetails=@()
    $policy=ConvertTo-VcdPolicyDocument -Snapshot $policy.sourceSnapshot
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway) -Policy $policy
    Assert-Equal 'Supported (read)' $result.Verdict
    Assert-True $result.CanProjectToV2
    Assert-True (-not $result.CanPlan)
    Assert-True (-not $result.CanApply)
}
Invoke-TestCase -Name 'Missing or untested evidence never promotes a gateway to Supported' -Body {
    foreach ($case in @(
        @{Field='vcdVersion';Value='';Expected='Unknown'},
        @{Field='vcdVersion';Value='10.7';Expected='Unknown'},
        @{Field='networkBacking';Value='';Expected='Unknown'},
        @{Field='networkBacking';Value='NSX_V';Expected='Unsupported'},
        @{Field='gatewayMode';Value='';Expected='Unknown'},
        @{Field='gatewayMode';Value='LEGACY';Expected='Unsupported'}
    )) {
        $gateway=New-CapGateway
        $gateway.($case.Field)=$case.Value
        $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata $gateway -Policy (New-CapPolicy)
        Assert-Equal $case.Expected $result.Verdict
        Assert-True (-not $result.CanProjectToV2)
    }
}
Invoke-TestCase -Name 'API uncertainty and absent policy stay Unknown rather than supported' -Body {
    foreach ($api in @('39.0','40.0')) {
        $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion $api -VersionAdvertised:$false -GatewayMetadata (New-CapGateway) -Policy (New-CapPolicy)
        Assert-Equal 'Unknown' $result.Verdict
        Assert-True (-not $result.CanProjectToV2)
        Assert-True (-not $result.CanApply)
        if ($api -eq '40.0') {
            Assert-True (@($result.Findings | Where-Object { $_.Code -eq 'POLICY_API_UNVERIFIED' -and $_.Path -eq 'policy.apiVersion' }).Count -eq 1)
        }
    }
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway)
    Assert-Equal 'Unknown' $result.Verdict
    Assert-True (-not $result.CanInspectRaw)
    $policy=New-CapPolicy
    $policy.PSObject.Properties.Remove('apiVersion')
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway) -Policy $policy
    Assert-Equal 'Unknown' $result.Verdict
    Assert-True (@($result.Findings | Where-Object { $_.Code -eq 'POLICY_API_MISSING' -and $_.Path -eq 'policy.apiVersion' }).Count -eq 1)
    Assert-True (-not $result.CanProjectToV2)
}
Invoke-TestCase -Name 'Verified policy API mismatch remains Unsupported and blocks projection' -Body {
    $policy=New-CapPolicy
    $policy.apiVersion='40.0'
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway) -Policy $policy
    Assert-Equal 'Unsupported' $result.Verdict
    Assert-True (@($result.Findings | Where-Object { $_.Code -eq 'POLICY_API_MISMATCH' -and $_.Path -eq 'policy.apiVersion' }).Count -eq 1)
    Assert-True (-not $result.CanProjectToV2)
    Assert-True (-not $result.CanApply)
}
Invoke-TestCase -Name 'Wrong policy gateway and schema remain Unsupported even when API is unverified' -Body {
    foreach ($kind in @('gateway','schema')) {
        $policy=New-CapPolicy
        if ($kind -eq 'gateway') { $policy.gatewayId='urn:vcloud:gateway:another-gateway' }
        else { $policy.schemaVersion=99 }
        $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$false -GatewayMetadata (New-CapGateway) -Policy $policy
        Assert-Equal 'Unsupported' $result.Verdict
        Assert-True (-not $result.CanProjectToV2)
        Assert-True (-not $result.CanApply)
    }
}
Invoke-TestCase -Name 'Catalogue schema, unknown fields and write capability fail closed' -Body {
    $file=Join-Path ([IO.Path]::GetTempPath()) ('capabilities-'+[guid]::NewGuid().ToString('n')+'.json')
    try {
        foreach ($variant in @('future','write','extra')) {
            $copy=ConvertFrom-Json -InputObject (ConvertTo-Json $capCatalogue -Depth 30)
            switch ($variant) {
                future { $copy.catalogueSchemaVersion=2 }
                write { $copy.liveWriteSupported=$true }
                extra { $copy | Add-Member -NotePropertyName bypass -NotePropertyValue $true }
            }
            [IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject $copy -Depth 30))
            Assert-Throws { Read-VcdCapabilityCatalogue -Path $file }
        }
    } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
}

Invoke-TestCase -Name 'Discovery placeholders remain Unknown until a complete gateway assessment' -Body {
    Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdDiscovery.psm1') -ErrorAction Stop
    $entry=New-VcdUnknownCapability -GatewayId $capGateway
    Assert-Equal 'Unknown' $entry.Verdict
    Assert-True (-not $entry.CanApply)
}

Invoke-TestCase -Name 'Unknown firewall and group root properties remain raw and block projection' -Body {
    $policy=New-CapPolicy
    $policy.sourceSnapshot.firewall | Add-Member -NotePropertyName futureFirewallMode -NotePropertyValue 'UNRECOGNISED'
    $policy.sourceSnapshot.firewallGroupSummaries[0] | Add-Member -NotePropertyName futureGroupSelector -NotePropertyValue 'dynamic'
    $policy=ConvertTo-VcdPolicyDocument -Snapshot $policy.sourceSnapshot
    $result=Get-VcdCapabilityAssessment -Catalogue $capCatalogue -GatewayId $capGateway -ApiVersion '39.0' -VersionAdvertised:$true -GatewayMetadata (New-CapGateway) -Policy $policy
    $paths=@($result.Findings | ForEach-Object { $_.Path })
    Assert-True ($paths -contains 'firewall.futureFirewallMode')
    Assert-True (@($paths | Where-Object { $_ -like '*futureGroupSelector' }).Count -eq 1)
    Assert-True (-not $result.CanProjectToV2)
}

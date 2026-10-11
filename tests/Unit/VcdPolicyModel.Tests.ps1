# The native test harness dot-sources test files into one scope. Import the
# composite application modules first (they load dependencies privately and
# sometimes with -Force), then explicitly expose the functions under test.
# Never Force-import modules again from individual test cases: doing so can
# invalidate public commands that earlier test cases resolved successfully.
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdSnapshot.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Planning\Planning.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\State\VcdPolicyRepository.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdApi.psm1') -Force -ErrorAction Stop
# These imports must be LAST and without -Force, to expose the final module
# instances to the tests in Windows PowerShell 5.1.
foreach ($module in @(
    'src\Domain\State\StateModel.psm1',
    'src\Infrastructure\State\StateRepository.psm1',
    'src\Application\VcdRead\VcdSnapshot.psm1',
    'src\Domain\State\VcdPolicyModel.psm1',
    'src\Infrastructure\State\VcdPolicyRepository.psm1',
    'src\Domain\Planning\Planning.psm1',
    'src\Infrastructure\VcdApi\VcdApi.psm1',
    'src\Application\VcdRead\VcdReadOperation.psm1'
)) {
    Import-Module (Join-Path $ProjectRoot $module) -Global -ErrorAction Stop
}
. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcd106.ps1')

Invoke-TestCase -Name 'VCD v3 dependency exports are available before model tests run' -Body {
    foreach ($name in @(
        'ConvertTo-VcdPolicyDocument', 'Confirm-VcdPolicyDocument',
        'Get-VcdPolicyCanonicalJson', 'Get-VcdPolicyFingerprint',
        'Get-VcdPolicyObservedPath', 'Read-VcdPolicyObserved', 'Save-VcdPolicyObserved',
        'ConvertTo-VcdLegacyPolicyProjection', 'New-NetworkChangePlan',
        'ConvertTo-NetworkStateDocument', 'Read-NetworkStateView',
        'Invoke-VcdReadOperation'
    )) {
        Assert-True ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "Missing required command: $name"
    }
}

function New-Issue2Snapshot {
    $summaryOne = (Read-Vcd106Fixture 'firewall-groups-page1.json').values[0]
    $summaryTwo = (Read-Vcd106Fixture 'firewall-groups-page2.json').values[0]
    $reservations = (Read-Vcd106Fixture 'manual-ip-reservations.json').values
    return [pscustomobject]@{
        schemaVersion=1; capturedUtc='2026-10-11T09:00:00Z'
        gatewayId='urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
        networkIds=@('urn:vcloud:network:44444444-4444-4444-8444-444444444444')
        firewall=(Read-Vcd106Fixture 'edge-firewall-rules.json')
        firewallGroupSummaries=@($summaryOne,$summaryTwo)
        ipSetDetails=@((Read-Vcd106Fixture 'firewall-group-ipset.json'))
        manualIpReservations=@($reservations)
    }
}

function New-Issue2LegacySnapshot {
    $path = Join-Path $ProjectRoot 'tests\Fixtures\Phase3'
    $firewall = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $path 'firewall.json')))
    $group = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $path 'group.json')))
    $reservations = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $path 'reservations.json')))
    return [pscustomobject]@{
        gatewayId='urn:vcloud:gateway:55555555-5555-4555-8555-555555555555'
        capturedUtc='2026-10-11T09:00:00Z'
        networkIds=@('urn:vcloud:network:44444444-4444-4444-8444-444444444444')
        firewall=$firewall
        firewallGroupSummaries=@([pscustomobject]@{ id=$group.id; typeValue='IP_SET'; name=$group.name })
        ipSetDetails=@($group)
        manualIpReservations=@($reservations.values)
    }
}

Invoke-TestCase -Name 'VCD v3 policy normalizes all three firewall sections without collapsing rule order' -Body {
    $policy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
    Assert-Equal 3 $policy.schemaVersion
    Assert-Equal 1 $policy.sections.systemRules.Count
    Assert-Equal 2 $policy.sections.userDefinedRules.Count
    Assert-Equal 1 $policy.sections.defaultRules.Count
    Assert-Equal 'SQL Always On Listener' $policy.sections.userDefinedRules[0].name
    Assert-Equal 'Block legacy RDP' $policy.sections.userDefinedRules[1].name
    Assert-Equal 1 $policy.sections.userDefinedRules[1].position
    Assert-Equal $false $policy.sections.userDefinedRules[1].enabled
    Assert-Equal 'log-sql-01' $policy.sections.userDefinedRules[0].raw.loggingId
    Assert-True $policy.sections.systemRules[0].capabilities.CanInspect
    Assert-True (-not $policy.sections.defaultRules[0].capabilities.CanEdit)
}

Invoke-TestCase -Name 'VCD v3 policy retains advanced services, direct addresses, version, scope and comments' -Body {
    $policy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
    $sql = $policy.sections.userDefinedRules[0]
    Assert-Equal 'SQL-TCP-1433' $sql.applicationPortProfiles[0].name
    Assert-Equal '10.60.20.30' $sql.destinationAddresses[0]
    Assert-Equal 'IN_OUT' $sql.raw.direction
    Assert-Equal 'CHG-1024' $sql.raw.comments
    Assert-Equal 7 $sql.raw.version.version
    Assert-True (-not $sql.capabilities.CanProjectToV2)
    Assert-True (-not $sql.capabilities.CanApply)
    Assert-Equal '3389' $policy.sections.userDefinedRules[1].rawPortProtocols[0].ports
}

Invoke-TestCase -Name 'VCD v3 policy retains unresolved security group without inventing empty membership' -Body {
    $policy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
    Assert-Equal 2 $policy.firewallGroups.Count
    Assert-Equal 'VM_CRITERIA' $policy.firewallGroups[1].typeValue
    Assert-True (-not $policy.firewallGroups[1].membershipResolved)
    $ref = $policy.sections.userDefinedRules[1].destinationGroups[0]
    Assert-Equal 'VM_CRITERIA' $ref.typeValue
    Assert-True (-not $ref.membershipResolved)
    Assert-True ($policy.sections.userDefinedRules[1].capabilities.Reasons.Count -gt 0)
}

Invoke-TestCase -Name 'VCD v3 canonical JSON roundtrip preserves null, missing, ordering and unknown fields' -Body {
    $snapshot = New-Issue2Snapshot
    $snapshot.firewall.userDefinedRules[0] | Add-Member -NotePropertyName futureRuleSetting -NotePropertyValue ([pscustomobject]@{ nullable=$null; flags=@('z','a'); nested=[pscustomobject]@{ a=0 } })
    $document = ConvertTo-VcdPolicyDocument -Snapshot $snapshot
    Assert-True ($document.sections.userDefinedRules[0].unknownFields -contains 'futureRuleSetting')
    Assert-True ($document.sections.userDefinedRules[0].unknownFields[0] -is [string]) 'Unknown field names must be plain strings, not adapted PSObjects'
    $expected = Get-VcdPolicyCanonicalJson -Document $document
    $restored = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $document -Depth 100)
    $actual = Get-VcdPolicyCanonicalJson -Document $restored
    Assert-Equal $expected $actual
    Assert-Equal 'futureRuleSetting' $restored.sections.userDefinedRules[0].unknownFields[0]
    Assert-True ($null -eq $restored.sourceSnapshot.firewall.userDefinedRules[0].futureRuleSetting.nullable)
    Assert-Equal 'a' $restored.sourceSnapshot.firewall.userDefinedRules[0].futureRuleSetting.flags[1]
    Assert-True (-not $restored.sections.userDefinedRules[0].capabilities.CanProjectToV2)
}

Invoke-TestCase -Name 'VCD v3 canonical fingerprint ignores capture timestamp but detects rule ordering' -Body {
    $left = New-Issue2Snapshot
    $right = New-Issue2Snapshot
    $right.capturedUtc='2026-11-11T00:00:00Z'
    $first = ConvertTo-VcdPolicyDocument -Snapshot $left
    $second = ConvertTo-VcdPolicyDocument -Snapshot $right
    Assert-Equal (Get-VcdPolicyFingerprint -Document $first) (Get-VcdPolicyFingerprint -Document $second)
    $right.firewall.userDefinedRules=@($right.firewall.userDefinedRules[1],$right.firewall.userDefinedRules[0])
    $changed=ConvertTo-VcdPolicyDocument -Snapshot $right
    Assert-True ((Get-VcdPolicyFingerprint -Document $first) -cne (Get-VcdPolicyFingerprint -Document $changed))
}

Invoke-TestCase -Name 'VCD v3 rejects malformed sections, duplicate IDs and non-array collections' -Body {
    $missing=New-Issue2Snapshot
    $missing.firewall.PSObject.Properties.Remove('defaultRules')
    Assert-Throws { ConvertTo-VcdPolicyDocument -Snapshot $missing }
    $duplicates=New-Issue2Snapshot
    $duplicates.firewall.userDefinedRules[1].id=$duplicates.firewall.userDefinedRules[0].id
    Assert-Throws { ConvertTo-VcdPolicyDocument -Snapshot $duplicates }
    $wrong=New-Issue2Snapshot
    $wrong.firewall.userDefinedRules=[pscustomobject]@{id='fake'}
    Assert-Throws { ConvertTo-VcdPolicyDocument -Snapshot $wrong }
}

Invoke-TestCase -Name 'VCD legacy projection remains strict and readable for the supported v2 subset' -Body {
    $legacy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2LegacySnapshot)
    Assert-True $legacy.sections.userDefinedRules[0].capabilities.CanProjectToV2
    $docs = ConvertTo-VcdLegacyPolicyProjection -Policy $legacy
    Assert-Equal 2 $docs.edgeFirewallRules.schemaVersion
    Assert-Equal 1 $docs.edgeFirewallRules.items.Count
    $advanced = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
    Assert-Throws { ConvertTo-VcdLegacyPolicyProjection -Policy $advanced }
}

Invoke-TestCase -Name 'VCD v3 storage is independent of v2 state and can be reloaded intact' -Body {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-policy-test-' + [guid]::NewGuid().ToString('n'))
    try {
        $policy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
        $saved = Save-VcdPolicyObserved -StateRoot $root -Environment 'env01' -Scope 'edge01' -Document $policy
        Assert-True ([IO.File]::Exists($saved.Path))
        $found = Read-VcdPolicyObserved -StateRoot $root -Environment 'env01' -Scope 'edge01'
        Assert-True $found.Available
        Assert-Equal (Get-VcdPolicyCanonicalJson $policy) (Get-VcdPolicyCanonicalJson $found.Document)
        Assert-True (-not (Read-NetworkStateView -StateRoot $root -Environment 'env01' -Scope 'edge01' -View observed).Available)
        Assert-True (-not (Read-NetworkStateView -StateRoot $root -Environment 'env01' -Scope 'edge01' -View desired).Available)
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'VCD v3 storage rejects mismatched hash, path traversal and corrupt documents' -Body {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-policy-test-' + [guid]::NewGuid().ToString('n'))
    try {
        $policy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
        Assert-Throws { Save-VcdPolicyObserved -StateRoot $root -Environment '../invalid' -Scope 'edge01' -Document $policy }
        $saved = Save-VcdPolicyObserved -StateRoot $root -Environment 'env01' -Scope 'edge01' -Document $policy
        Assert-Throws { Save-VcdPolicyObserved -StateRoot $root -Environment 'env01' -Scope 'edge01' -Document $policy -ExpectedSha256 ('a'*64) }
        Assert-Equal $saved.Sha256 (Get-NetworkFileSha256 -Path $saved.Path)
        [IO.File]::WriteAllText($saved.Path, '{"schemaVersion":55}')
        Assert-Throws { Read-VcdPolicyObserved -StateRoot $root -Environment 'env01' -Scope 'edge01' }
        Assert-Throws { Save-VcdPolicyObserved -StateRoot $root -Environment 'env01' -Scope 'edge01' -Document $policy }
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'VCD v3 cannot be loaded as v2 state and future schemas are rejected' -Body {
    $policy = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
    Assert-Throws { ConvertTo-NetworkStateDocument -InputObject $policy }
    $policy.schemaVersion=4
    Assert-Throws { Confirm-VcdPolicyDocument -Document $policy }
}

Invoke-TestCase -Name 'VCD v3 policy blocks a legacy plan even with complete v2 baselines' -Body {
    $legacy = ConvertTo-VcdLegacyPolicyProjection -Policy (ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2LegacySnapshot))
    $view = [pscustomobject]@{ Available=$true; Documents=$legacy }
    $advanced = ConvertTo-VcdPolicyDocument -Snapshot (New-Issue2Snapshot)
    $plan = New-NetworkChangePlan -Desired $view -Applied $view -Observed $view -Environment 'env01' -Scope 'edge01' -VcdPolicy $advanced
    Assert-True $plan.blocked
    Assert-True ($plan.policyFindings.Count -gt 0)
    Assert-True ((@($plan.warnings) -join ';') -match 'read-only')
    Assert-Equal 0 $plan.actions.Count
}

Invoke-TestCase -Name 'VCD 10.6 advanced snapshot saves a separate v3 policy but never overwrites legacy observed files' -Body {
    $fake = New-FakeVcd106
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-policy-test-' + [guid]::NewGuid().ToString('n'))
    try {
        $observed = Join-Path $root 'state\env01\edge01\observed'
        [void][IO.Directory]::CreateDirectory($observed)
        [IO.File]::WriteAllText((Join-Path $observed 'sentinel.txt'), 'do not change')
        $config = [pscustomobject]@{
            mode='Live'; apiUrl='https://vcd.example.test:8443'; apiVersion='39.0'
            gatewayId=$fake.GatewayId; networkIds=@($fake.NetworkId)
        }
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory (Join-Path $root 'reports') -RequestSender $fake.RequestSender -WriteObserved -StateRoot (Join-Path $root 'state') -Environment env01 -Scope edge01 }
        Assert-Equal 'do not change' ([IO.File]::ReadAllText((Join-Path $observed 'sentinel.txt')))
        $v3 = Read-VcdPolicyObserved -StateRoot (Join-Path $root 'state') -Environment env01 -Scope edge01
        Assert-True $v3.Available
        Assert-Equal 2 $v3.Document.sections.userDefinedRules.Count
        Assert-Equal 'SQL-TCP-1433' $v3.Document.sections.userDefinedRules[0].applicationPortProfiles[0].name
        Assert-Equal 1 (@(Get-ChildItem (Join-Path $root 'reports') -Filter 'vcd-snapshot-*.json').Count)
        Assert-Equal 8 $fake.Calls.Count
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'VCD 10.6 policy-only import succeeds safely with advanced rules and leaves v2 absent' -Body {
    $fake = New-FakeVcd106
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vcd-policy-test-' + [guid]::NewGuid().ToString('n'))
    try {
        $config = [pscustomobject]@{
            mode='Live'; apiUrl='https://vcd.example.test:8443'; apiVersion='39.0'
            gatewayId=$fake.GatewayId; networkIds=@($fake.NetworkId)
        }
        $result = Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory (Join-Path $root 'reports') -RequestSender $fake.RequestSender -WritePolicyObserved -StateRoot (Join-Path $root 'state') -Environment env01 -Scope edge01
        Assert-True $result.Connected
        Assert-True $result.PolicyImported
        Assert-True (-not $result.ObservedImported)
        Assert-True ([IO.File]::Exists($result.PolicyPath))
        $v3 = Read-VcdPolicyObserved -StateRoot (Join-Path $root 'state') -Environment env01 -Scope edge01
        Assert-Equal 2 $v3.Document.sections.userDefinedRules.Count
        Assert-True (-not (Read-NetworkStateView -StateRoot (Join-Path $root 'state') -Environment env01 -Scope edge01 -View observed).Available)
        Assert-Equal 8 $fake.Calls.Count
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'VCD v3 commands remain exported after successive live read tests' -Body {
    foreach ($name in @(
        'ConvertTo-VcdPolicyDocument', 'ConvertTo-VcdLegacyPolicyProjection',
        'ConvertTo-NetworkStateDocument', 'Read-NetworkStateView',
        'Read-VcdPolicyObserved', 'Invoke-VcdReadOperation'
    )) {
        Assert-True ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) "Command disappeared after read/import: $name"
    }
}

Invoke-TestCase -Name 'VCD v3 contradictory active and enabled flags remain inspectable but cannot project' -Body {
    $snapshot = New-Issue2LegacySnapshot
    $rule = $snapshot.firewall.userDefinedRules[0]
    $rule | Add-Member -NotePropertyName enabled -NotePropertyValue $false
    $policy = ConvertTo-VcdPolicyDocument -Snapshot $snapshot
    Assert-True (-not $policy.sections.userDefinedRules[0].capabilities.CanProjectToV2)
    Assert-True ((@($policy.sections.userDefinedRules[0].capabilities.Reasons) -join ';') -match 'Conflicting enabled/active')
    Assert-True (-not $policy.sections.userDefinedRules[0].capabilities.CanEdit)
    Assert-Throws { ConvertTo-VcdLegacyPolicyProjection -Policy $policy }
}

Invoke-TestCase -Name 'VCD v3 fingerprint treats unknown explicit null as different from missing property' -Body {
    $first = New-Issue2Snapshot
    $second = New-Issue2Snapshot
    $second.firewall.userDefinedRules[0] | Add-Member -NotePropertyName vendorFeature -NotePropertyValue $null
    $doc1 = ConvertTo-VcdPolicyDocument -Snapshot $first
    $doc2 = ConvertTo-VcdPolicyDocument -Snapshot $second
    Assert-True ((Get-VcdPolicyFingerprint -Document $doc1) -cne (Get-VcdPolicyFingerprint -Document $doc2))
    Assert-True (-not $doc2.sections.userDefinedRules[0].capabilities.CanProjectToV2)
}

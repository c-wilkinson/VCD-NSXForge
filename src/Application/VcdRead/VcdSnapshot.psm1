# Read-only orchestration. A raw snapshot always preserves complete VCD results;
# v3 normalization is lossless; legacy v2 projection stays fail-closed.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\VcdApi\VcdApi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\State\StateRepository.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\StateModel.psm1') -Force
# Avoid Force-reloading a shared policy module: doing so can remove its exported
# functions from the importing test runner or another already-loaded module.
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\VcdPolicyModel.psm1') -ErrorAction Stop

function Get-VcdReadSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Client,
          [Parameter(Mandatory)][string]$GatewayId,
          [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NetworkIds,
          [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    if (-not $GatewayId.StartsWith('urn:vcloud:')) { throw 'A gateway URN is required.' }
    $CancellationToken.ThrowIfCancellationRequested()
    $rules = Get-VcdEdgeFirewallRules -Client $Client -GatewayId $GatewayId -CancellationToken $CancellationToken
    if ($null -eq $rules -or $rules.PSObject.Properties.Name -notcontains 'userDefinedRules' -or $null -eq $rules.userDefinedRules) { throw 'VCD firewall response has no valid userDefinedRules array.' }
    $CancellationToken.ThrowIfCancellationRequested()
    $summaries = @(Get-VcdFirewallGroups -Client $Client -GatewayId $GatewayId -CancellationToken $CancellationToken)
    $details = [System.Collections.Generic.List[object]]::new()
    foreach ($summary in $summaries) {
        $CancellationToken.ThrowIfCancellationRequested()
        if ([string]$summary.typeValue -ne 'IP_SET') { continue }
        $details.Add((Get-VcdFirewallGroupDetails -Client $Client -GroupId ([string]$summary.id) -CancellationToken $CancellationToken))
    }
    $reservations = [System.Collections.Generic.List[object]]::new()
    foreach ($networkId in $NetworkIds) {
        $CancellationToken.ThrowIfCancellationRequested()
        foreach ($entry in @(Get-VcdManualIpReservations -Client $Client -NetworkId $networkId -CancellationToken $CancellationToken)) { $reservations.Add($entry) }
    }
    $CancellationToken.ThrowIfCancellationRequested()
    return [pscustomobject]@{
        schemaVersion = 1
        capturedUtc = [DateTime]::UtcNow.ToString('o')
        gatewayId = $GatewayId
        networkIds = @($NetworkIds)
        firewall = $rules
        firewallGroupSummaries = @($summaries)
        ipSetDetails = @($details.ToArray())
        manualIpReservations = @($reservations.ToArray())
    }
}

function Get-VcdMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-VcdResourceKey {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$') {
        throw "VCD resource ID has no stable UUID. Cannot create safe state key."
    }
    return 'vcd-' + $Matches[1].ToLowerInvariant()
}

function ConvertTo-VcdObservedDocuments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    if ((Get-VcdMember $Snapshot.firewall 'status') -and [string]$Snapshot.firewall.status -ne 'REALIZED') {
        throw 'VCD firewall is not in REALIZED status; observed import is blocked.'
    }
    $sets = [System.Collections.Generic.List[object]]::new()
    $knownGroups = @{}
    foreach ($group in @($Snapshot.ipSetDetails)) {
        if ([string]$group.typeValue -ne 'IP_SET' -or $null -eq $group.ipAddresses -or @($group.ipAddresses).Count -eq 0) {
            throw 'An IP Set has no supported IP address array. Import blocked.'
        }
        $key = Get-VcdResourceKey -Id ([string]$group.id)
        $knownGroups[[string]$group.id] = $key
        $sets.Add([pscustomobject]@{
            key = $key; name = [string]$group.name
            description = [string](Get-VcdMember $group 'description')
            addresses = @($group.ipAddresses)
        })
    }
    $rules = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($rule in @($Snapshot.firewall.userDefinedRules)) {
        # Fail-closed for new semantic API fields unknown to this model.
        $documentedFields = @(
            'id','name','description','sourceFirewallGroups','sourceFirewallIpAddresses',
            'destinationFirewallGroups','destinationFirewallIpAddresses',
            'applicationPortProfiles','rawPortProtocols','ipProtocol','actionValue','direction',
            'logging','networkContextProfiles','active','version','comments','appliedTo',
            'loggingId','relativePosition'
        )
        foreach ($field in @($rule.PSObject.Properties.Name)) {
            if ($field -cnotin $documentedFields) { throw "Rule '$($rule.name)' contains unknown VCD property '$field'. Import blocked." }
        }
        foreach ($feature in @('applicationPortProfiles','rawPortProtocols','networkContextProfiles','sourceFirewallIpAddresses','destinationFirewallIpAddresses')) {
            if ($null -ne (Get-VcdMember $rule $feature) -and @((Get-VcdMember $rule $feature)).Count -gt 0) {
                throw "Rule '$($rule.name)' uses '$feature', which Phase 2 cannot model safely. Raw snapshot is available; observed state unchanged."
            }
        }
        if ($null -ne (Get-VcdMember $rule 'appliedTo') -or $null -ne (Get-VcdMember $rule 'direction') -or $null -ne (Get-VcdMember $rule 'ipProtocol') -or (Get-VcdMember $rule 'comments')) {
            throw "Rule '$($rule.name)' has scope, direction or protocol attributes not represented in the Phase 2 schema."
        }
        $sourceKeys = @()
        $sourceGroups = Get-VcdMember $rule 'sourceFirewallGroups'
        if ($null -ne $sourceGroups) {
            foreach ($ref in @($sourceGroups)) {
                if (-not $knownGroups.ContainsKey([string]$ref.id)) { throw 'Firewall rule references an unmodelled Firewall Group.' }
                $sourceKeys += $knownGroups[[string]$ref.id]
            }
        }
        $destKeys = @()
        $destinationGroups = Get-VcdMember $rule 'destinationFirewallGroups'
        if ($null -ne $destinationGroups) {
            foreach ($ref in @($destinationGroups)) {
                if (-not $knownGroups.ContainsKey([string]$ref.id)) { throw 'Firewall rule references an unmodelled Firewall Group.' }
                $destKeys += $knownGroups[[string]$ref.id]
            }
        }
        if ($rule.actionValue -cnotin @('ALLOW','DROP','REJECT') -or $rule.active -isnot [bool] -or $rule.logging -isnot [bool]) {
            throw "Rule '$($rule.name)' cannot be mapped without losing action or boolean flags."
        }
        $rules.Add([pscustomobject]@{
            key = (Get-VcdResourceKey -Id ([string]$rule.id)); name = [string]$rule.name
            description = [string](Get-VcdMember $rule 'description'); order = $index
            action = [string]$rule.actionValue; enabled = [bool]$rule.active; logging = [bool]$rule.logging
            sourceIpSets = @($sourceKeys); destinationIpSets = @($destKeys); services = @()
        })
        $index++
    }
    $ips = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Snapshot.manualIpReservations)) {
        $addresses = [string]$item.ipAddresses
        if ($addresses.Contains(',') -or $addresses.Contains('-') -or -not (Test-NetworkIpAddress -Address $addresses)) {
            throw "Reservation '$($item.name)' contains a range/multiple addresses not representable as a single Phase 2 reservation."
        }
        if ($null -eq $item.networkRef -or -not $item.networkRef.id) { throw 'VCD reservation missing networkRef.id.' }
        if ((Get-VcdMember $item 'expirationType') -or (Get-VcdMember $item 'expirationDate') -or (Get-VcdMember $item 'expirationVAppRef') -or (Get-VcdMember $item 'allowIpUsageByServiceOrVm') -or (Get-VcdMember $item 'removeIpAfterUsage')) {
            throw "Reservation '$($item.name)' has lifecycle properties not represented in Phase 2."
        }
        $ips.Add([pscustomobject]@{ key = (Get-VcdResourceKey -Id ([string]$item.id));
            networkId = [string]$item.networkRef.id; address = $addresses; description = [string](Get-VcdMember $item 'description') })
    }
    $documents = [ordered]@{}
    $resources = @{ ipSets = $sets.ToArray(); edgeFirewallRules = $rules.ToArray(); manualIpReservations = $ips.ToArray() }
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $doc = [pscustomobject]@{ schemaVersion = 2; resourceKind = $kind; items = @($resources[$kind]) }
        Confirm-NetworkDocument -Document $doc
        $documents[$kind] = $doc
    }
    return $documents
}

function ConvertTo-VcdLegacyPolicyProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy)
    $null = Confirm-VcdPolicyDocument -Document $Policy
    if ([string]$Policy.status -cne 'REALIZED') { throw 'Only REALIZED firewall policies can be projected into the legacy v2 model.' }
    if (@($Policy.sections.systemRules).Count -gt 0 -or @($Policy.sections.defaultRules).Count -gt 0) {
        throw 'Protected system/default firewall rules are not represented in the v2 schema; only v3 preserves the complete policy.'
    }
    foreach ($group in @($Policy.firewallGroups)) {
        if ($group.typeValue -cne 'IP_SET' -or -not $group.membershipResolved) {
            throw "Firewall Group '$($group.id)' is not safely representable in v2."
        }
    }
    foreach ($rule in @($Policy.sections.userDefinedRules)) {
        if (-not $rule.capabilities.CanProjectToV2) {
            throw "Rule '$($rule.name)' cannot be projected to v2: $(@($rule.capabilities.Reasons) -join '; ')"
        }
    }
    # This function retains the strict legacy conversion checks for reservations,
    # unknown semantics, references and supported service fields.
    return (ConvertTo-VcdObservedDocuments -Snapshot $Policy.sourceSnapshot)
}

function Save-VcdRawSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$OutputDirectory)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
    $filename = 'vcd-snapshot-{0}.json' -f ([guid]::NewGuid().ToString('n'))
    $file = Join-Path $OutputDirectory $filename
    $json = ConvertTo-Json -InputObject $Snapshot -Depth 50
    [IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
    return $file
}

function Publish-VcdObservedView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Documents,
          [Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope)
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        if (-not $Documents.Contains($kind)) { throw "Missing required document '$kind'." }
        Confirm-NetworkDocument -Document $Documents[$kind]
    }
    $destination = Get-NetworkStateDirectory -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View observed
    $scopeFolder = [IO.Path]::GetDirectoryName($destination)
    [void][IO.Directory]::CreateDirectory($scopeFolder)
    $lockPath = Join-Path $scopeFolder 'observed-write.lock'
    $lock = $null
    $staging = Join-Path $scopeFolder ('observed-staging-' + [guid]::NewGuid().ToString('n'))
    $backup = Join-Path $scopeFolder ('observed-backup-' + [guid]::NewGuid().ToString('n'))
    $movedOld = $false; $installed = $false
    try {
        $lock = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        [void][IO.Directory]::CreateDirectory($staging)
        $filenames = @{ipSets='ip-sets.json';edgeFirewallRules='firewall-rules.json';manualIpReservations='ip-reservations.json'}
        foreach ($kind in @(Get-NetworkResourceKinds)) {
            $serialized = ConvertTo-Json -InputObject $Documents[$kind] -Depth 40
            [IO.File]::WriteAllText((Join-Path $staging $filenames[$kind]), $serialized, [System.Text.UTF8Encoding]::new($false))
        }
        if ([IO.Directory]::Exists($destination)) {
            [IO.Directory]::Move($destination, $backup)
            $movedOld = $true
        }
        [IO.Directory]::Move($staging, $destination)
        $installed = $true
        if ($movedOld) {
            # A failed backup cleanup must not report an applied snapshot as failed.
            try { [IO.Directory]::Delete($backup, $true) }
            catch { Write-Warning 'Observed view committed; cleanup of the previous snapshot backup failed.' }
        }
        return $destination
    }
    catch {
        if ($movedOld -and -not $installed -and [IO.Directory]::Exists($backup) -and -not [IO.Directory]::Exists($destination)) {
            [IO.Directory]::Move($backup, $destination)
        }
        throw
    }
    finally {
        if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
        if ($null -ne $lock) { $lock.Dispose(); if ([IO.File]::Exists($lockPath)) { [IO.File]::Delete($lockPath) } }
    }
}

Export-ModuleMember -Function Get-VcdReadSnapshot, ConvertTo-VcdObservedDocuments, ConvertTo-VcdLegacyPolicyProjection, Save-VcdRawSnapshot, Publish-VcdObservedView

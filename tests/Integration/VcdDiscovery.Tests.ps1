# VCD 10.6 read-only discovery: live-shaped fixtures, no network or credentials.
Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdDiscovery.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdApi.psm1') -ErrorAction Stop

function New-DiscoveryTestConfig {
    $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
    $cfg.vcd.mode='Live'
    $cfg.vcd.apiUrl='https://vcd.example.test:8443'
    $cfg.vcd.gatewayId=''
    $cfg.vcd.networkIds=@()
    return $cfg.vcd
}
function New-DiscoveryTestSender {
    param([ValidateSet('Normal','Forbidden','RateLimited','ServerFailure','BadPages','BadParent','NoOrganisation','EmptyResources','DuplicateIds')][string]$Mode='Normal')
    $org='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    $other='urn:vcloud:org:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    $vdc1='urn:vcloud:vdc:11111111-1111-4111-8111-111111111111'
    $vdc2='urn:vcloud:vdc:22222222-2222-4222-8222-222222222222'
    $g1='urn:vcloud:gateway:33333333-3333-4333-8333-333333333333'
    $g2='urn:vcloud:gateway:44444444-4444-4444-8444-444444444444'
    $calls=[System.Collections.Generic.List[object]]::new()
    $collections=@{
        orgs=@(
            [pscustomobject]@{id=$org;name='Tenant A'},
            [pscustomobject]@{id=$other;name='Tenant B'})
        vdcs=@(
            [pscustomobject]@{id=$vdc1;name='Production';org=[pscustomobject]@{id=$org}},
            [pscustomobject]@{id=$vdc2;name='Production';org=[pscustomobject]@{id=$org}},
            [pscustomobject]@{id='urn:vcloud:vdc:99999999-9999-4999-8999-999999999999';name='Other VDC';org=[pscustomobject]@{id=$other}})
        edgeGateways=@(
            [pscustomobject]@{id=$g1;name='edge-common';orgRef=[pscustomobject]@{id=$org};orgVdc=[pscustomobject]@{id=$vdc1}},
            [pscustomobject]@{id=$g2;name='edge-common';orgRef=[pscustomobject]@{id=$org};orgVdc=[pscustomobject]@{id=$vdc2}},
            [pscustomobject]@{id='urn:vcloud:gateway:99999999-9999-4999-8999-999999999999';name='edge-other';orgRef=[pscustomobject]@{id=$other}})
        orgVdcNetworks=@(
            [pscustomobject]@{id='urn:vcloud:network:55555555-5555-4555-8555-555555555555';name='APP';networkType='NAT_ROUTED';orgRef=[pscustomobject]@{id=$org};orgVdc=[pscustomobject]@{id=$vdc1};connection=[pscustomobject]@{routerRef=[pscustomobject]@{id=$g1}}},
            [pscustomobject]@{id='urn:vcloud:network:66666666-6666-4666-8666-666666666666';name='APP';networkType='NAT_ROUTED';orgRef=[pscustomobject]@{id=$org};orgVdc=[pscustomobject]@{id=$vdc2};connection=[pscustomobject]@{routerRef=[pscustomobject]@{id=$g2}}})
    }
    if ($Mode -eq 'BadParent') { $collections.vdcs[0].org.id='' }
    if ($Mode -eq 'NoOrganisation') { $collections.orgs=@() }
    if ($Mode -eq 'EmptyResources') { foreach ($kind in @('vdcs','edgeGateways','orgVdcNetworks')) { $collections[$kind]=@() } }
    if ($Mode -eq 'DuplicateIds') { $collections.edgeGateways[1].id=$collections.edgeGateways[0].id }
    $sender={
        param($request)
        $calls.Add($request)
        if ($request.Method -cne 'GET') { throw 'Unexpected live write.' }
        $url=[uri]$request.Uri
        if ($url.GetLeftPart([UriPartial]::Authority) -cne 'https://vcd.example.test:8443') { throw 'Unexpected host.' }
        if ($url.AbsolutePath -eq '/api/versions') { return '<SupportedVersions><VersionInfo><Version>39.0</Version></VersionInfo></SupportedVersions>' }
        if ($url.AbsolutePath -eq '/cloudapi/1.0.0/sessions/current') { return [pscustomobject]@{id='urn:vcloud:session:test';user='engineer';orgRef=[pscustomobject]@{id=$org}} }
        if ($url.AbsolutePath -notmatch '^/cloudapi/1\.0\.0/(orgs|vdcs|edgeGateways|orgVdcNetworks)$') { throw 'Unexpected discovery route.' }
        if ($Mode -eq 'Forbidden') { throw 'VCD GET failed: HTTP 403.' }
        if ($Mode -eq 'RateLimited') { throw 'VCD GET failed: HTTP 429.' }
        if ($Mode -eq 'ServerFailure') { throw 'VCD GET failed: HTTP 503.' }
        $kind=($url.AbsolutePath -split '/')[-1]
        $page=1;$pageSize=25
        $query=[string]$url.Query
        if ($query -match '(?:\?|&)page=(\d+)') { $page=[int]$Matches[1] }
        if ($query -match '(?:\?|&)pageSize=(\d+)') { $pageSize=[int]$Matches[1] }
        if ($kind -eq 'orgVdcNetworks' -and $pageSize -gt 32) { throw 'Network API page size exceeded.' }
        $items=@($collections[$kind]);$pages=[int][math]::Ceiling($items.Count/[double]$pageSize)
        if ($Mode -eq 'BadPages' -and $kind -eq 'edgeGateways') { return [pscustomobject]@{values=@($items);page=20;pageCount=1;resultTotal=$items.Count} }
        $start=($page-1)*$pageSize
        # PowerShell emits no pipeline objects for @() in an if expression.
        # Assigning that result produces $null, NOT the empty JSON array that
        # a genuine, successful VCD collection response must return.
        [object[]]$values = @()
        if ($start -lt $items.Count) {
            $values = [object[]]@($items | Select-Object -Skip $start -First $pageSize)
        }
        return [pscustomobject]@{values=$values;page=$page;pageCount=$pages;pageSize=$pageSize;resultTotal=$items.Count}
    }.GetNewClosure()
    return [pscustomobject]@{RequestSender=$sender;Calls=$calls}
}

Invoke-TestCase -Name 'Read-only VCD discovery exposes the scoped hierarchy with duplicate names and stable IDs' -Body {
    $fake=New-DiscoveryTestSender
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('discovery-'+[guid]::NewGuid().ToString('n'))
    $result=Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory $tmp -RequestSender $fake.RequestSender -DiscoverOnly
    Assert-True $result.Discovered
    Assert-True $result.Inventory.Complete
    Assert-Equal 'PermissionScoped' $result.Inventory.Visibility
    Assert-Equal 1 @($result.Inventory.Organisations).Count
    Assert-Equal 2 @($result.Inventory.Vdcs).Count
    Assert-Equal 2 @($result.Inventory.Gateways).Count
    Assert-Equal 2 @($result.Inventory.Networks).Count
    Assert-True ($result.Inventory.Gateways[0].Id -cne $result.Inventory.Gateways[1].Id)
    Assert-True ($result.Inventory.Networks[0].GatewayId -cne $result.Inventory.Networks[1].GatewayId)
    Assert-True (-not [IO.Directory]::Exists($tmp))
    Assert-True (@($fake.Calls | Where-Object {$_.Method -cne 'GET'}).Count -eq 0)
    Assert-Equal 6 $fake.Calls.Count
}

Invoke-TestCase -Name 'VCD discovery works without gateway and network URNs and does not alter configuration' -Body {
    $config=New-DiscoveryTestConfig
    $fake=New-DiscoveryTestSender
    $null=Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory 'ignored' -RequestSender $fake.RequestSender -DiscoverOnly
    Assert-Equal '' $config.gatewayId
    Assert-Equal 0 @($config.networkIds).Count
}

Invoke-TestCase -Name 'VCD discovery rejects conflicts with connection-only and observed-state writing' -Body {
    $config=New-DiscoveryTestConfig;$fake=New-DiscoveryTestSender
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory 'ignored' -RequestSender $fake.RequestSender -DiscoverOnly -ConnectionOnly }
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $config -OutputDirectory 'ignored' -RequestSender $fake.RequestSender -DiscoverOnly -WriteObserved }
    Assert-Equal 0 $fake.Calls.Count
}

Invoke-TestCase -Name 'VCD discovery fails closed on 403 429 503 and inconsistent pagination instead of claiming empty results' -Body {
    foreach ($mode in @('Forbidden','RateLimited','ServerFailure','BadPages')) {
        $fake=New-DiscoveryTestSender -Mode $mode
        $folder=Join-Path ([IO.Path]::GetTempPath()) ('discovery-'+[guid]::NewGuid().ToString('n'))
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory $folder -RequestSender $fake.RequestSender -DiscoverOnly }
        Assert-True (-not [IO.Directory]::Exists($folder))
    }
}

Invoke-TestCase -Name 'VCD discovery refuses missing target or unverifiable parent ownership' -Body {
    foreach ($mode in @('NoOrganisation','BadParent')) {
        $fake=New-DiscoveryTestSender -Mode $mode
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory 'ignored' -RequestSender $fake.RequestSender -DiscoverOnly }
    }
}

Invoke-TestCase -Name 'VCD discovery cancellation before read makes no calls or local changes' -Body {
    $fake=New-DiscoveryTestSender;$cts=[Threading.CancellationTokenSource]::new();$cts.Cancel()
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('discovery-'+[guid]::NewGuid().ToString('n'))
    try {
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory $tmp -RequestSender $fake.RequestSender -DiscoverOnly -CancellationToken $cts.Token }
        Assert-Equal 0 $fake.Calls.Count
        Assert-True (-not [IO.Directory]::Exists($tmp))
    } finally { $cts.Dispose() }
}

Invoke-TestCase -Name 'Discovery collection paging refuses invalid JSON collection values' -Body {
    $sender={ param($req) [pscustomobject]@{values='wrong-type';pageCount=1;resultTotal=1} }
    $api=New-VcdApiClient -BaseUri ([uri]'https://vcd.example.test') -RequestSender $sender
    Assert-Throws { Get-VcdDiscoveryCollection -Client $api -Kind orgs }
}

Invoke-TestCase -Name 'Discovery worker contract validates the optional discovery flag' -Body {
    Import-Module (Join-Path $ProjectRoot 'src\Runtime\WorkerOperations.psm1') -ErrorAction Stop
    $args=@{VcdConfiguration=(New-DiscoveryTestConfig); OutputDirectory='ignored';ConnectionOnly=$false;DiscoverOnly=$true}
    Confirm-WorkerOperationArguments -Operation VcdRead -Arguments $args
    $args.DiscoverOnly='true'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation VcdRead -Arguments $args }
}

Invoke-TestCase -Name 'An empty authorised VDC/gateway/network collection is complete but explicitly permission-scoped' -Body {
    $fake=New-DiscoveryTestSender -Mode EmptyResources
    $out=Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory 'ignored' -RequestSender $fake.RequestSender -DiscoverOnly
    Assert-True $out.Inventory.Complete
    Assert-Equal 'PermissionScoped' $out.Inventory.Visibility
    Assert-Equal 0 @($out.Inventory.Vdcs).Count
    Assert-Equal 0 @($out.Inventory.Gateways).Count
    Assert-Equal 0 @($out.Inventory.Networks).Count
}

Invoke-TestCase -Name 'Discovery rejects repeated gateway ID rather than merging duplicate resources' -Body {
    $fake=New-DiscoveryTestSender -Mode DuplicateIds
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory 'ignored' -RequestSender $fake.RequestSender -DiscoverOnly }
}

Invoke-TestCase -Name 'Discovery cancellation between collections does not publish partial inventory' -Body {
    $fake=New-DiscoveryTestSender
    $cts=[Threading.CancellationTokenSource]::new()
    $inner=$fake.RequestSender
    # The request list is reference-backed. A plain $count++ in a scriptblock
    # executes in a child scope and can reset on every invocation.
    $sender={ param($request)
        $out=& $inner $request
        if ($fake.Calls.Count -eq 4) { $cts.Cancel() }
        return $out
    }.GetNewClosure()
    try {
        $root=Join-Path ([IO.Path]::GetTempPath()) ('discovery-'+[guid]::NewGuid().ToString('n'))
        Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration (New-DiscoveryTestConfig) -OutputDirectory $root -RequestSender $sender -DiscoverOnly -CancellationToken $cts.Token }
        Assert-True $cts.IsCancellationRequested
        Assert-True (-not [IO.Directory]::Exists($root))
        Assert-Equal 4 $fake.Calls.Count
    } finally { $cts.Dispose() }
}

# Read-only complete authenticated preflight using the v10.6 API fixture transport.
Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Capabilities\VcdCapabilityModel.psm1') -ErrorAction Stop
. (Join-Path $ProjectRoot 'tests\Mocks\FakeVcd106.ps1')

function New-CapPreflightConfig {
    return [pscustomobject]@{
        mode='Live';apiUrl='https://vcd.example.test:8443';apiVersion='39.0'
        timeoutSeconds=15;loginScope='Tenant';tenantContextOrgId='urn:vcloud:org:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        gatewayId='urn:vcloud:gateway:55555555-5555-4555-8555-555555555555';networkIds=@()
    }
}
function New-CapPreflightSender {
    param([ValidateSet('Known','Unknown','Forbidden','RateLimited','Unavailable','Unsupported')][string]$Kind='Known')
    $fake=New-FakeVcd106
    $requests=[System.Collections.Generic.List[object]]::new()
    $original=$fake.RequestSender
    $sender={
        param($request)
        $requests.Add($request)
        if ($request.Method -cne 'GET') { throw 'Preflight attempted a mutation.' }
        $path=([uri]$request.Uri).AbsolutePath
        if ($path -match '^/cloudapi/1.0.0/edgeGateways/[^/]+$') {
            if ($Kind -eq 'Forbidden') { throw 'VCD GET failed: HTTP 403.' }
            if ($Kind -eq 'RateLimited') { throw 'VCD GET failed: HTTP 429.' }
            if ($Kind -eq 'Unavailable') { throw 'VCD GET failed: HTTP 503.' }
            $result=& $original $request
            if ($Kind -eq 'Known') {
                $result | Add-Member -NotePropertyName vcdVersion -NotePropertyValue '10.6'
                $result | Add-Member -NotePropertyName gatewayMode -NotePropertyValue 'NSXT_BACKED'
                $result | Add-Member -NotePropertyName networkBacking -NotePropertyValue 'NSX_T'
            }
            if ($Kind -eq 'Unsupported') {
                $result | Add-Member -NotePropertyName vcdVersion -NotePropertyValue '10.6'
                $result | Add-Member -NotePropertyName gatewayMode -NotePropertyValue 'NSXT_BACKED'
                $result | Add-Member -NotePropertyName networkBacking -NotePropertyValue 'NSX_V'
            }
            return $result
        }
        return & $original $request
    }.GetNewClosure()
    [pscustomobject]@{RequestSender=$sender;Calls=$requests}
}
Invoke-TestCase -Name 'Preflight consumes VCD 10.6 fixture read-only and returns advanced field verdict with no files' -Body {
    $fake=New-CapPreflightSender
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('cap-preflight-'+[guid]::NewGuid().ToString('n'))
    $result=Invoke-VcdReadOperation -VcdConfiguration (New-CapPreflightConfig) -OutputDirectory $folder -RequestSender $fake.RequestSender -CapabilitiesOnly
    Assert-True $result.CapabilitiesAssessed
    Assert-Equal 'Partial' $result.Capability.Verdict
    Assert-True (@($result.Capability.Findings | Where-Object { $_.Path -like '*applicationPortProfiles' }).Count -gt 0)
    Assert-True (@($fake.Calls | Where-Object { $_.Method -cne 'GET' }).Count -eq 0)
    Assert-True (-not [IO.Directory]::Exists($folder))
}
Invoke-TestCase -Name 'Missing gateway capability flags yield Unknown with no mutation' -Body {
    $fake=New-CapPreflightSender -Kind Unknown
    $result=Invoke-VcdReadOperation -VcdConfiguration (New-CapPreflightConfig) -OutputDirectory ([IO.Path]::GetTempPath()) -RequestSender $fake.RequestSender -CapabilitiesOnly
    Assert-Equal 'Unknown' $result.Capability.Verdict
    Assert-True (-not $result.Capability.CanApply)
}
Invoke-TestCase -Name 'Known incompatible backing is Unsupported even when firewall GET succeeds' -Body {
    $fake=New-CapPreflightSender -Kind Unsupported
    $result=Invoke-VcdReadOperation -VcdConfiguration (New-CapPreflightConfig) -OutputDirectory ([IO.Path]::GetTempPath()) -RequestSender $fake.RequestSender -CapabilitiesOnly
    Assert-Equal 'Unsupported' $result.Capability.Verdict
}
Invoke-TestCase -Name '403 during capability preflight reports Unknown without publishing raw or observed state' -Body {
    $fake=New-CapPreflightSender -Kind Forbidden
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('cap-denied-'+[guid]::NewGuid().ToString('n'))
    $result=Invoke-VcdReadOperation -VcdConfiguration (New-CapPreflightConfig) -OutputDirectory $folder -RequestSender $fake.RequestSender -CapabilitiesOnly
    Assert-Equal 'Unknown' $result.Capability.Verdict
    Assert-True (-not [IO.Directory]::Exists($folder))
}
Invoke-TestCase -Name 'Preflight cannot be combined with write or discovery flags' -Body {
    $fake=New-CapPreflightSender
    $cfg=New-CapPreflightConfig
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $cfg -OutputDirectory 'unused' -RequestSender $fake.RequestSender -CapabilitiesOnly -ConnectionOnly }
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $cfg -OutputDirectory 'unused' -RequestSender $fake.RequestSender -CapabilitiesOnly -DiscoverOnly }
    Assert-Throws { Invoke-VcdReadOperation -VcdConfiguration $cfg -OutputDirectory 'unused' -RequestSender $fake.RequestSender -CapabilitiesOnly -WriteObserved }
    Assert-Equal 0 $fake.Calls.Count
}

Invoke-TestCase -Name 'Unadvertised API version returns Unknown and does not authenticate or save files' -Body {
    $fake=New-CapPreflightSender
    $cfg=New-CapPreflightConfig
    $cfg.apiVersion='40.0'
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('cap-version-'+[guid]::NewGuid().ToString('n'))
    $result=Invoke-VcdReadOperation -VcdConfiguration $cfg -OutputDirectory $tmp -RequestSender $fake.RequestSender -CapabilitiesOnly
    Assert-Equal 'Unknown' $result.Capability.Verdict
    Assert-True (-not $result.Connected)
    Assert-Equal 1 $fake.Calls.Count
    Assert-True (-not [IO.Directory]::Exists($tmp))
}

Invoke-TestCase -Name 'Capability preflight reports rate limiting and service failure as Unknown without writing snapshots' -Body {
    foreach ($kind in @('RateLimited','Unavailable')) {
        $fake=New-CapPreflightSender -Kind $kind
        $root=Join-Path ([IO.Path]::GetTempPath()) ('cap-error-'+[guid]::NewGuid().ToString('n'))
        $result=Invoke-VcdReadOperation -VcdConfiguration (New-CapPreflightConfig) -OutputDirectory $root -RequestSender $fake.RequestSender -CapabilitiesOnly
        Assert-Equal 'Unknown' $result.Capability.Verdict
        Assert-True (-not $result.Capability.CanApply)
        Assert-True (-not [IO.Directory]::Exists($root))
    }
}

Invoke-TestCase -Name 'Enterprise simulator preflight reads synthetic metadata and reports known advanced port limits' -Body {
    Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorServer.psm1') -ErrorAction Stop
    Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -ErrorAction Stop
    $data=Import-SimulatorTopology -Path (Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json')
    $gw=@($data.gateways | Where-Object { $_.domain -eq 'DomainB' -and $_.tier -eq 1 })[0]
    $route=Get-Command Invoke-SimulatorRoute
    $sender={
        param($request)
        $uri=[uri]$request.Uri;$query=@{}
        if ($uri.Query) {
            foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
                $part=$pair.Split('=',2)
                $query[[uri]::UnescapeDataString($part[0])]=if ($part.Count -gt 1) { [uri]::UnescapeDataString($part[1]) } else { '' }
            }
        }
        if ($request.Method -cne 'GET') { throw 'Simulator preflight must remain GET-only.' }
        $result=& $route -Dataset $data -Method $request.Method -Path $uri.AbsolutePath -Query $query -Authorization 'Bearer simulator-read-only'
        if ($result.StatusCode -ne 200) { throw ('Synthetic HTTP '+$result.StatusCode) }
        if ($result.Body -is [string]) { return $result.Body }
        return ($result.Body | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json)
    }.GetNewClosure()
    $cfg=(Read-AppConfiguration -ApplicationRoot $ProjectRoot).vcd
    $cfg.mode='Simulator';$cfg.apiUrl='http://127.0.0.1:8765'
    $cfg.gatewayId=$gw.gatewayId;$cfg.networkIds=@($gw.networkId)
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('sim-cap-'+[guid]::NewGuid().ToString('n'))
    $result=Invoke-VcdReadOperation -VcdConfiguration $cfg -OutputDirectory $tmp -RequestSender $sender -CapabilitiesOnly
    Assert-Equal 'Partial' $result.Capability.Verdict
    Assert-Equal '10.6' $result.Capability.VcdRelease
    Assert-Equal 'NSXT_BACKED' $result.Capability.GatewayMode
    Assert-Equal 'NSX_T' $result.Capability.NetworkBacking
    Assert-True (@($result.Capability.Findings | Where-Object { $_.Path -like '*.rawPortProtocols' }).Count -gt 0)
    Assert-Equal 0 (@($result.Capability.Findings | Where-Object { $_.Code -in @('RELEASE_UNKNOWN','MODE_UNKNOWN','BACKING_UNKNOWN','UNKNOWN_POLICY_FIELD') }).Count)
    Assert-True (-not $result.Capability.CanProjectToV2)
    Assert-True (-not $result.Capability.CanApply)
    Assert-True (-not [IO.Directory]::Exists($tmp))
}

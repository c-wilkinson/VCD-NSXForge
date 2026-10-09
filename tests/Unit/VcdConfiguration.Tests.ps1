Import-Module (Join-Path $ProjectRoot 'src\Application\Configuration\Configuration.psm1') -Force

function Test-InvalidVcdConfig {
    param([scriptblock]$Edit)
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('vcd-config-' + [guid]::NewGuid().ToString('n'))
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'config'))
        $cfg = Get-Content (Join-Path $ProjectRoot 'config\application.json') -Raw | ConvertFrom-Json
        if ($cfg.vcd.PSObject.Properties.Name -contains 'mode') { $cfg.vcd.mode='Live' }
        & $Edit $cfg.vcd
        $cfg | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $scratch 'config\application.json') -Encoding UTF8
        Assert-Throws { Read-AppConfiguration -ApplicationRoot $scratch }
    }
    finally { if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) } }
}

Invoke-TestCase -Name 'VCD API origin is externally configurable and defaults to offline' -Body {
    $cfg = Read-AppConfiguration -ApplicationRoot $ProjectRoot
    Assert-True ($cfg.vcd.apiUrl -eq '' -or $cfg.vcd.apiUrl.StartsWith('https://') -or ($cfg.vcd.mode -eq 'Simulator' -and $cfg.vcd.apiUrl.StartsWith('http://127.0.0.1:'))) 'URL is optional or the explicitly selected loopback simulator'
    Assert-Equal '39.0' $cfg.vcd.apiVersion
    Assert-True ($cfg.vcd.timeoutSeconds -ge 5 -and $cfg.vcd.timeoutSeconds -le 180)
    Assert-True ($cfg.vcd.authentication -in @('Credential','BearerToken'))
    Assert-True ($cfg.vcd.loginScope -in @('Tenant','Provider')) 'A developer may configure provider login'
}

Invoke-TestCase -Name 'VCD API config rejects HTTP credentials embedded URLs paths and unknown API versions' -Body {
    Test-InvalidVcdConfig { param($c) $c.apiUrl='http://unsafe.example.test' }
    Test-InvalidVcdConfig { param($c) $c.apiUrl='https://name:pass@vcd.example.test' }
    Test-InvalidVcdConfig { param($c) $c.apiUrl='https://vcd.example.test/cloudapi' }
    Test-InvalidVcdConfig { param($c) $c.apiUrl='https://vcd.example.test?x=1' }
    Test-InvalidVcdConfig { param($c) $c.apiVersion='38.1' }
    Test-InvalidVcdConfig { param($c) $c.timeoutSeconds=181 }
    Test-InvalidVcdConfig { param($c) $c.authentication='None' }
    Test-InvalidVcdConfig { param($c) $c.loginScope='Unknown' }
}

Invoke-TestCase -Name 'VCD API config rejects invalid URNs and duplicate networks' -Body {
    Test-InvalidVcdConfig { param($c) $c.gatewayId='../gateway' }
    Test-InvalidVcdConfig { param($c) $c.networkIds=@('some-network') }
    Test-InvalidVcdConfig { param($c) $c.networkIds=@('urn:vcloud:network:11111111-1111-4111-8111-111111111111','urn:vcloud:network:11111111-1111-4111-8111-111111111111') }
}

Invoke-TestCase -Name 'Simulator mode only accepts explicit loopback HTTP while live mode requires HTTPS' -Body {
    Test-InvalidVcdConfig { param($c) $c.mode='Simulator'; $c.apiUrl='http://192.168.1.1:8765' }
    Test-InvalidVcdConfig { param($c) $c.mode='Simulator'; $c.apiUrl='http://localhost:8765' }
    Test-InvalidVcdConfig { param($c) $c.mode='Simulator'; $c.apiUrl='http://127.0.0.1:8765/cloudapi' }
    Test-InvalidVcdConfig { param($c) $c.mode='Invalid' }
}

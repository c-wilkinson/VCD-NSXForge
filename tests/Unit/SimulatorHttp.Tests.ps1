Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorHttp.psm1') -ErrorAction Stop

Invoke-TestCase -Name 'Simulator write HTTP boundary never permits remote origins or live TLS destinations' -Body {
    Assert-Equal 'http://127.0.0.1:8765' (Confirm-SimulatorOrigin 'http://127.0.0.1:8765')
    foreach ($url in @('https://vcd.example.test','http://127.0.0.2:8765','http://localhost:8765','http://127.0.0.1:8765/cloudapi','http://user:pass@127.0.0.1:8765','http://127.0.0.1:8765/?evil=1')) {
        Assert-Throws { Confirm-SimulatorOrigin $url }
    }
    Assert-Throws { Invoke-SimulatorApi -ApiUrl 'https://vcd.example.test' -Method POST -Resource apply -Payload @{a=1} }
    Assert-Throws { Invoke-SimulatorApi -ApiUrl 'http://127.0.0.1:8765' -Method POST -Resource state -Payload @{a=1} }
    Assert-Throws { Invoke-SimulatorApi -ApiUrl 'http://127.0.0.1:8765' -Method GET -Resource apply }
}

Invoke-TestCase -Name 'Live VCD HTTP transport remains read-only while simulator is isolated' -Body {
    $real=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1'))
    Assert-True (-not $real.Contains('/__simulator/v1/apply'))
    $sim=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorHttp.psm1'))
    Assert-True ($sim.Contains('127.0.0.1'))
    Assert-True ($sim.Contains('simulator-edit-only'))
    Assert-True (-not $sim.Contains('SkipCertificateCheck'))
}

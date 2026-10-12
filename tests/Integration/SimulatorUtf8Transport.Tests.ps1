# Verify the *actual* Windows PowerShell 5.1 Invoke-RestMethod HTTP byte path,
# not only PowerShell object-to-JSON-to-object round trips.
Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorHttp.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\Simulator\SimulatorClient.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Application\Editing\NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $ProjectRoot 'src\Domain\Topology\TopologyPolicy.psm1') -ErrorAction Stop

Invoke-TestCase -Name 'Enterprise simulator accepts v3 frozen approval over real UTF-8 HTTP with non-ASCII draft contents' -Body {
    $topologyPath=Join-Path $ProjectRoot 'simulator\scenarios\enterprise-lab\topology.json'
    $serverModule=Join-Path $ProjectRoot 'src\Infrastructure\Simulator\SimulatorServer.psm1'
    $topology=Import-SimulatorTopology -Path $topologyPath
    $gateway=@($topology.gateways | Where-Object { $_.domain -ceq 'DomainB' -and $_.tier -eq 1 })[0]

    # Request a free loopback port; this test NEVER contacts a remote host and
    # NEVER uses the persistent enterprise-lab runtime-state file.
    $portProbe=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,0)
    $portProbe.Start()
    $port=[int]$portProbe.LocalEndpoint.Port
    $portProbe.Stop()
    $origin=('http://127.0.0.1:{0}' -f $port)
    $job=$null
    try {
        $job=Start-Job -ScriptBlock {
            param($modulePath,$scenarioPath,$serverPort)
            $ErrorActionPreference='Stop'
            Import-Module -Name $modulePath -ErrorAction Stop
            Start-VcdSimulatorServer -TopologyPath $scenarioPath -Port $serverPort
        } -ArgumentList @($serverModule,$topologyPath,$port)

        $ready=$false
        for ($attempt=0; $attempt -lt 45; $attempt++) {
            if ($job.State -in @('Failed','Stopped','Completed')) {
                $details=@(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue) -join ' '
                throw ('Isolated loopback simulator failed to start: '+$details)
            }
            try {
                $null=Invoke-SimulatorApi -ApiUrl $origin -Method GET -Resource scopes
                $ready=$true
                break
            }
            catch { Start-Sleep -Milliseconds 200 }
        }
        Assert-True $ready 'Isolated real HTTP simulator did not become ready.'

        # Read through the real HTTP transport, just like the WinForms editor.
        $baseline=Invoke-SimulatorApi -ApiUrl $origin -Method GET -Resource state -GatewayId ([string]$gateway.gatewayId)
        $draft=Copy-NetworkDocuments -Documents $baseline.documents
        $nextOrder=([int](($draft.edgeFirewallRules.items | Measure-Object -Property order -Maximum).Maximum))+1
        # The real enterprise lab has em dashes in reservation descriptions.
        # Use a generated Unicode character so this test also parses on PS5.1
        # when the test file was saved as UTF-8 without a BOM.
        $description='SYNTHETIC: SQL Server FCI node '+[char]0x2014+' FCI Node 1'
        $item=[pscustomobject]@{
            key='utf8-frozen-approval';name='UTF8 frozen approval';description=$description
            order=$nextOrder;action='ALLOW';enabled=$true;logging=$true
            sourceIpSets=@();destinationIpSets=@();services=@()
        }
        $draft=Set-NetworkDraftItem -Documents $draft -ResourceKind edgeFirewallRules -Item $item -Create
        $approved=Get-SimulatorDraftPlan -Baseline $baseline -DesiredDocuments $draft
        Assert-Equal 1 $approved.plan.summary.Create
        Assert-True (-not $approved.plan.blocked)
        # Simulate the worker event -> editor -> another worker boundary.
        $editorApproval=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $approved -Depth 45 -Compress)
        $result=Invoke-SimulatorApprovedApply -ApiUrl $origin -Approved $editorApproval -ActorDomain DomainA -ActorTier 0
        Assert-Equal 1 ([int]$result.revision) 'An approved Unicode-containing draft must apply over real HTTP.'

        # Confirm the server committed exactly the original Unicode text.
        $after=Invoke-SimulatorApi -ApiUrl $origin -Method GET -Resource state -GatewayId ([string]$gateway.gatewayId)
        $saved=@($after.documents.edgeFirewallRules.items | Where-Object { $_.key -ceq 'utf8-frozen-approval' })
        Assert-Equal 1 $saved.Count
        Assert-Equal $description ([string]$saved[0].description)
    }
    finally {
        if ($null -ne $job) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

param(
    [string]$Operation,
    $Arguments,
    $EventQueue,
    $Logger,
    [System.Threading.CancellationToken]$CancellationToken,
    [string]$OperationId,
    [string]$ApplicationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ApplicationRoot 'src\Runtime\WorkerOperations.psm1') -ErrorAction Stop
Confirm-WorkerOperationArguments -Operation $Operation -Arguments $Arguments
Import-Module (Join-Path $ApplicationRoot 'src\Infrastructure\Logging\Logging.psm1') -ErrorAction Stop

function Send-WorkerProgress {
    param([string]$Message, [int]$Percent)
    $EventQueue.Enqueue([pscustomobject]@{
        Type = 'Progress'
        OperationId = $OperationId
        Message = $Message
        Percent = $Percent
        WorkerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    })
}

Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'INFO' -OperationId $OperationId -Message "Started $Operation"
try {
    switch ($Operation) {
        'ProgressDemo' {
            for ($step = 1; $step -le 8; $step++) {
                $CancellationToken.ThrowIfCancellationRequested()
                Send-WorkerProgress -Message ("Simulated read-only step {0}/8" -f $step) -Percent ($step * 12)
                Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'INFO' -OperationId $OperationId -Message "Simulated step $step completed"
                for ($slice = 0; $slice -lt 5; $slice++) {
                    $CancellationToken.ThrowIfCancellationRequested()
                    [System.Threading.Thread]::Sleep(100)
                }
            }
            Send-WorkerProgress -Message 'Simulation finished' -Percent 100
        }
        'OfflinePlan' {
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Loading offline desired/applied/observed state' -Percent 15
            Import-Module (Join-Path $ApplicationRoot 'src\Application\Planning\OfflinePlan.psm1') -Force
            $plan = Get-OfflineNetworkPlan -StateRoot ([string]$Arguments.StateRoot) -Environment ([string]$Arguments.Environment) -Scope ([string]$Arguments.Scope)
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Building deterministic HTML and JSON reports' -Percent 65
            $reports = Export-OfflineNetworkPlan -Plan $plan -OutputDirectory ([string]$Arguments.OutputDirectory)
            $EventQueue.Enqueue([pscustomobject]@{
                Type = 'PlanSummary'; OperationId = $OperationId
                Message = ('{0}; blocked={1}; HTML={2}' -f $reports.Summary,$reports.Blocked,$reports.Html)
                Percent = 95; WorkerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            })
            Write-AppLog -Logger $Logger -Component 'OfflinePlan' -Level 'INFO' -OperationId $OperationId -Message ('Offline report written; blocked={0}' -f $reports.Blocked)
            Send-WorkerProgress -Message 'Offline plan report created (no VCD calls)' -Percent 100
        }
        'VcdRead' {
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Discovering VCD API versions and authenticating' -Percent 10
            Import-Module (Join-Path $ApplicationRoot 'src\Application\VcdRead\VcdReadOperation.psm1') -Force
            $parameters = @{
                VcdConfiguration = $Arguments.VcdConfiguration
                OutputDirectory = [string]$Arguments.OutputDirectory
                CancellationToken = $CancellationToken
                ConnectionOnly = [bool]$Arguments.ConnectionOnly
                DiscoverOnly = [bool]($Arguments.ContainsKey('DiscoverOnly') -and $Arguments.DiscoverOnly)
                CapabilitiesOnly = [bool]($Arguments.ContainsKey('CapabilitiesOnly') -and $Arguments.CapabilitiesOnly)
            }
            if ($Arguments.ContainsKey('Credential') -and $null -ne $Arguments.Credential) { $parameters.Credential = $Arguments.Credential }
            elseif ($Arguments.ContainsKey('BearerToken') -and $null -ne $Arguments.BearerToken) { $parameters.BearerToken = [string]$Arguments.BearerToken }
            # This operation is read-only; observed import is enabled only for explicit CLI use.
            $result = Invoke-VcdReadOperation @parameters
            if ($result.PSObject.Properties.Name -contains 'Discovered' -and $result.Discovered) {
                $inventory = $result.Inventory
                $EventQueue.Enqueue([pscustomobject]@{
                    Type = 'VcdDiscovery'; OperationId = $OperationId; Payload = $inventory
                    Message = ('Read-only discovery complete: {0} VDCs, {1} gateways, {2} networks (permission scoped)' -f @($inventory.Vdcs).Count, @($inventory.Gateways).Count, @($inventory.Networks).Count)
                    Percent = 95; WorkerThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
                })
                Send-WorkerProgress -Message 'Read-only VCD discovery complete; no configuration changed' -Percent 100
                break
            }
            if ($result.PSObject.Properties.Name -contains 'CapabilitiesAssessed' -and $result.CapabilitiesAssessed) {
                $report = $result.Capability
                $EventQueue.Enqueue([pscustomobject]@{
                    Type='VcdCapabilities'; OperationId=$OperationId; Payload=$report
                    Message=('Compatibility: {0}; {1} findings; live apply disabled' -f $report.Verdict,@($report.Findings).Count)
                    Percent=95; WorkerThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId
                })
                Send-WorkerProgress -Message 'Read-only compatibility preflight completed' -Percent 100
                break
            }
            # Read completed: a late cancel must not hide a snapshot already returned.
            Import-Module (Join-Path $ApplicationRoot 'src\Application\VcdRead\VcdReadSummary.psm1') -ErrorAction Stop
            $summary = New-VcdReadCompletionSummary -Result $result -ConnectionOnly:([bool]$Arguments.ConnectionOnly)
            $EventQueue.Enqueue([pscustomobject]@{
                Type = 'VcdSummary'; OperationId = $OperationId
                Message = $summary.Message
                Percent = 95; WorkerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            })
            Write-AppLog -Logger $Logger -Component 'VcdRead' -Level 'INFO' -OperationId $OperationId -Message $summary.LogMessage
            Send-WorkerProgress -Message $summary.ProgressMessage -Percent 100
        }
        { $_ -in @('SimulatorScopes','SimulatorLoadState','SimulatorPlan','SimulatorApply','SimulatorTraffic','SimulatorTrafficRead','SimulatorSaveDraft') } {
            Import-Module (Join-Path $ApplicationRoot 'src\Application\Simulator\SimulatorClient.psm1') -ErrorAction Stop
            $CancellationToken.ThrowIfCancellationRequested()
            Send-WorkerProgress -Message 'Working with local synthetic simulator' -Percent 15
            $url=[string]$Arguments.ApiUrl
            $name='';$payload=$null;$description='';$committed=$false
            switch ($Operation) {
                'SimulatorScopes' {
                    $payload=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource scopes -CancellationToken $CancellationToken
                    $name='Scopes';$description='Synthetic scopes loaded'
                }
                'SimulatorLoadState' {
                    $state=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource state -GatewayId ([string]$Arguments.GatewayId) -CancellationToken $CancellationToken
                    $history=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource traffic -GatewayId ([string]$Arguments.GatewayId) -CancellationToken $CancellationToken
                    $payload=[pscustomobject]@{State=$state;Events=@($history.events)}
                    $name='State';$description=('Synthetic state revision {0} retrieved' -f $state.revision)
                }
                'SimulatorPlan' {
                    $approved=Get-SimulatorDraftPlan -Baseline $Arguments.Baseline -DesiredDocuments $Arguments.Documents
                    Import-Module (Join-Path $ApplicationRoot 'src\Application\Planning\OfflinePlan.psm1') -ErrorAction Stop
                    $path=Export-OfflineNetworkPlan -Plan $approved.plan -OutputDirectory ([string]$Arguments.OutputDirectory) -BaseName ('simulator-plan-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
                    $counts=$approved.plan.summary
                    $description='Plan: +{0} ~{1} >{2} -{3}; blocked={4}; {5}' -f $counts.Create,$counts.Update,$counts.Move,$counts.Delete,$approved.plan.blocked,$path.Html
                    $payload=[pscustomobject]@{Approved=$approved;Summary=$description}
                    $name='Plan'
                }
                'SimulatorApply' {
                    Send-WorkerProgress -Message 'Checking approved plan and committing synthetic resources' -Percent 50
                    $result=Invoke-SimulatorApprovedApply -ApiUrl $url -Approved $Arguments.Approved -ActorDomain ([string]$Arguments.ActorDomain) -ActorTier ([int]$Arguments.ActorTier) -CancellationToken $CancellationToken
                    $committed=$true
                    $description='Synthetic deployment revision '+$result.revision
                    $payload=[pscustomobject]@{Message=$description;Result=$result};$name='Apply'
                }
                'SimulatorTrafficRead' {
                    $history=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource traffic -GatewayId ([string]$Arguments.GatewayId) -CancellationToken $CancellationToken
                    $payload=[pscustomobject]@{Events=@($history.events)}
                    $name='TrafficHistory';$description='Synthetic traffic history refreshed'
                }
                'SimulatorTraffic' {
                    $request=[pscustomobject]@{gatewayId=[string]$Arguments.GatewayId;sourceIp=[string]$Arguments.SourceIp;destinationIp=[string]$Arguments.DestinationIp;protocol=[string]$Arguments.Protocol;destinationPort=[int]$Arguments.DestinationPort}
                    $result=Invoke-SimulatorApi -ApiUrl $url -Method POST -Resource traffic -Payload $request -CancellationToken $CancellationToken
                    $description='{0} {1}:{2} -> {3}:{4} matched {5}' -f $result.verdict,$result.sourceIp,$result.protocol,$result.destinationIp,$result.destinationPort,$result.matchedRuleName
                    $history=Invoke-SimulatorApi -ApiUrl $url -Method GET -Resource traffic -GatewayId ([string]$Arguments.GatewayId) -CancellationToken $CancellationToken
                    $payload=[pscustomobject]@{Message=$description;Event=$result;Events=@($history.events)};$name='Traffic'
                }
                'SimulatorSaveDraft' {
                    Import-Module (Join-Path $ApplicationRoot 'src\Infrastructure\State\StateRepository.psm1') -ErrorAction Stop
                    $files=0
                    $CancellationToken.ThrowIfCancellationRequested()
                    # All three files form a logical save. Do not interrupt between files.
                    foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) {
                        $doc=$Arguments.Documents[$kind]
                        $path=Get-NetworkStateDocumentPath -StateRoot ([string]$Arguments.StateRoot) -Environment 'simulator' -Scope ([string]$Arguments.Scope) -View desired -ResourceKind $kind
                        $checksum=Get-NetworkFileSha256 -Path $path
                        $null=Save-NetworkStateDocument -StateRoot ([string]$Arguments.StateRoot) -Environment 'simulator' -Scope ([string]$Arguments.Scope) -View desired -Document $doc -ExpectedSha256 $checksum
                        $files++
                    }
                    $committed=$true
                    $description="Saved $files desired JSON files to the local simulator state repository"
                    $payload=[pscustomobject]@{Message=$description};$name='Draft'
                }
            }
            if (-not $committed) { $CancellationToken.ThrowIfCancellationRequested() }
            $EventQueue.Enqueue([pscustomobject]@{
                Type='SimulatorData';Name=$name;Message=$description;Payload=$payload
                OperationId=$OperationId;Percent=95;WorkerThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId
            })
            Send-WorkerProgress -Message $description -Percent 100
        }
        'SaveRuleTemplate' {
            $CancellationToken.ThrowIfCancellationRequested()
            Import-Module (Join-Path $ApplicationRoot 'src\Application\Editing\NetworkRuleTemplates.psm1') -ErrorAction Stop
            Send-WorkerProgress -Message 'Saving reusable local firewall rule template' -Percent 35
            $saved=Save-NetworkRuleTemplate -Path ([string]$Arguments.TemplatePath) -Rule $Arguments.Rule -Name ([string]$Arguments.TemplateName) -BuiltInPath ([string]$Arguments.BuiltInPath)
            # A successful local write must not be reported as rolled back on late cancellation.
            $EventQueue.Enqueue([pscustomobject]@{
                Type='SimulatorData';Name='TemplateSaved';Message=('Saved local template '+$saved.name)
                Payload=[pscustomobject]@{Message=('Saved template '+$saved.name)}
                OperationId=$OperationId;Percent=95;WorkerThreadId=[Threading.Thread]::CurrentThread.ManagedThreadId
            })
            Send-WorkerProgress -Message 'Local template saved; no live VCD changes' -Percent 100
        }
        'FailureDemo' {
            Send-WorkerProgress -Message 'Preparing simulated failure' -Percent 15
            [System.Threading.Thread]::Sleep(300)
            $CancellationToken.ThrowIfCancellationRequested()
            throw 'Deliberate demonstration failure; no VCD call was made.'
        }
        default { throw "Unsupported operation: $Operation" }
    }
    Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'INFO' -OperationId $OperationId -Message "Succeeded $Operation"
}
catch [System.OperationCanceledException] {
    # The dispatcher uses this explicit evidence rather than treating any failure after Cancel() as cancellation.
    $EventQueue.Enqueue([pscustomobject]@{Type='WorkerCancellationObserved';OperationId=$OperationId})
    Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'WARN' -OperationId $OperationId -Message "Cancelled $Operation"
    throw
}
catch {
    if ($Operation -eq 'VcdRead') {
        Write-AppLog -Logger $Logger -Component 'VcdRead' -Level 'ERROR' -OperationId $OperationId -Message 'VCD read failed; details withheld to avoid leaking server or credential material.'
        throw 'VCD read failed or was denied; consult the safe diagnostic status.'
    }
    Write-AppLog -Logger $Logger -Component 'DemoOperation' -Level 'ERROR' -OperationId $OperationId -Message ("Failed {0}: {1}" -f $Operation, $_.Exception.Message)
    throw
}

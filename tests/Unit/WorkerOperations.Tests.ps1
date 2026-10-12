Import-Module (Join-Path $ProjectRoot 'src\Runtime\WorkerOperations.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Runtime\Dispatcher.psm1') -Force

Invoke-TestCase -Name 'VCD read operation contract recognises isolated read-only capability preflight' -Body {
    Confirm-WorkerOperationArguments -Operation VcdRead -Arguments @{VcdConfiguration=[pscustomobject]@{};OutputDirectory='reports';ConnectionOnly=$false;CapabilitiesOnly=$true}
    Assert-Throws { Confirm-WorkerOperationArguments -Operation VcdRead -Arguments @{VcdConfiguration=[pscustomobject]@{};OutputDirectory='reports';ConnectionOnly=$true;CapabilitiesOnly=$true} }
}
Invoke-TestCase -Name 'Every published worker operation has a single, unique definition' -Body {
    $definitions = @(Get-WorkerOperationDefinitions)
    Assert-Equal 11 $definitions.Count
    Assert-Equal $definitions.Count (@($definitions.Name | Sort-Object -Unique).Count)
    foreach ($definition in $definitions) {
        Assert-True ($definition.Kind -in @('Demo','Offline','ReadOnly','Simulator')) "Unknown operation mode $($definition.Name)"
        Assert-True ($definition.SupportsCancellation) "Missing cancellation contract: $($definition.Name)"
    }
    Assert-True ('SaveRuleTemplate' -in @($definitions.Name)) 'Editor template saving is a registered operation'
}

Invoke-TestCase -Name 'Registry and top-level worker switch cover exactly the same operations' -Body {
    # Inspect AST selectors, not incidental string mentions within worker comments.
    $path = Join-Path $ProjectRoot 'src\Runtime\Invoke-WorkerOperation.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 (@($errors).Count)
    $switches = @($ast.FindAll({param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst] -and
        $node.Condition.Extent.Text -eq '$Operation'
    }, $true) | Sort-Object { $_.Extent.StartOffset })
    Assert-True ($switches.Count -ge 1) 'Top-level worker operation switch is absent'
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($clause in $switches[0].Clauses) {
        foreach ($match in [regex]::Matches($clause.Item1.Extent.Text, "'([A-Za-z][A-Za-z0-9]*)'")) {
            $names.Add($match.Groups[1].Value)
        }
    }
    $actual = @($names | Sort-Object -Unique)
    $expected = @((Get-WorkerOperationDefinitions).Name | Sort-Object -Unique)
    Assert-Equal ($expected -join ',') ($actual -join ',') 'Worker handlers and public operation registry differ'
}

Invoke-TestCase -Name 'All UI worker launches refer to registered operation names' -Body {
    $definitions = @((Get-WorkerOperationDefinitions).Name)
    foreach ($file in @('MainForm.psm1','NetworkEditorForm.psm1')) {
        $contents = [IO.File]::ReadAllText((Join-Path $ProjectRoot "src\Presentation\WinForms\$file"))
        $pattern = if ($file -eq 'MainForm.psm1') { '& \$startOperation ''([A-Za-z0-9]+)''' } else { '& \$start ''([A-Za-z0-9]+)''' }
        $found = @([regex]::Matches($contents, $pattern))
        Assert-True ($found.Count -gt 0) "No worker operation calls detected in $file"
        foreach ($match in $found) {
            Assert-True ($match.Groups[1].Value -in $definitions) "Unregistered UI operation $($match.Groups[1].Value) in $file"
        }
    }
}

Invoke-TestCase -Name 'Contract rejects unsupported operation and malformed arguments before worker creation' -Body {
    Assert-Throws { Confirm-WorkerOperationArguments -Operation 'NotARealOperation' } 'Unknown operation must fail'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation OfflinePlan -Arguments @{} } 'Required fields must be supplied'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation ProgressDemo -Arguments @{ Extra='ignored' } } 'Unknown arguments must not be silently ignored'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation SaveRuleTemplate -Arguments @{Rule=[pscustomobject]@{};TemplateName='';TemplatePath='x';BuiltInPath='y'} } 'Blank name must fail'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation VcdRead -Arguments @{VcdConfiguration=[pscustomobject]@{};OutputDirectory='x';ConnectionOnly='yes'} } 'Boolean strings must fail'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation SimulatorTraffic -Arguments @{ApiUrl='http://127.0.0.1:12000';GatewayId='g';SourceIp='x';DestinationIp='y';Protocol='TCP';DestinationPort=65536} } 'Invalid port must fail'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation SimulatorScopes -Arguments @{ApiUrl='https://production.example:443'} } 'Live endpoints cannot be used for simulator operations'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation SimulatorScopes -Arguments @{ApiUrl='http://localhost:12000'} } 'Simulator host is strictly 127.0.0.1'
    Assert-Throws { Confirm-WorkerOperationArguments -Operation SimulatorScopes -Arguments @{ApiUrl='http://127.0.0.1:12000/path'} } 'Simulator URL path is forbidden'
    Confirm-WorkerOperationArguments -Operation SimulatorScopes -Arguments @{ApiUrl='http://127.0.0.1:12000'}
    Confirm-WorkerOperationArguments -Operation VcdRead -Arguments @{VcdConfiguration=[pscustomobject]@{};OutputDirectory='reports';ConnectionOnly=$true}
}

Invoke-TestCase -Name 'Dispatcher validates startup without creating an invalid worker job' -Body {
    $log = [pscustomobject]@{}
    $dispatcher = New-WorkerDispatcher -ApplicationRoot $ProjectRoot -Logger $log -MaximumWorkers 1
    try {
        Assert-Throws { Start-BackgroundOperation -Dispatcher $dispatcher -Operation 'UnknownWorker' } 'Invalid operation rejected'
        Assert-Throws { Start-BackgroundOperation -Dispatcher $dispatcher -Operation 'SimulatorApply' -Arguments @{} } 'Missing required data rejected'
        Assert-Equal 0 (Get-RunningOperationCount -Dispatcher $dispatcher)
        Close-WorkerDispatcher -Dispatcher $dispatcher
        Assert-Throws { Start-BackgroundOperation -Dispatcher $dispatcher -Operation ProgressDemo } 'Cannot start on disposed dispatcher'
    }
    finally {
        if (-not $dispatcher.Closed -and (Get-RunningOperationCount -Dispatcher $dispatcher) -eq 0) { Close-WorkerDispatcher -Dispatcher $dispatcher }
    }
}

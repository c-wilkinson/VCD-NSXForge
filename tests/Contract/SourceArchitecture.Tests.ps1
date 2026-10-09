Invoke-TestCase -Name 'Every source file parses under the native PowerShell parser' -Body {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1','.psm1') })
    $files += Get-Item (Join-Path $ProjectRoot 'Start-VcdNetworkManager.ps1')
    Assert-True ($files.Count -ge 8)
    foreach ($file in $files) {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 (@($errors).Count) "Invalid PowerShell syntax in $($file.Name)"
    }
}

Invoke-TestCase -Name 'UI and domain-independent runtime never issue external HTTP calls' -Body {
    $folders = @('src\Presentation','src\Runtime','src\Application','src\Infrastructure\Logging')
    foreach ($folder in $folders) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot $folder) -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
            $content = [IO.File]::ReadAllText($file.FullName)
            foreach ($cmd in @('Invoke-RestMethod','Invoke-WebRequest','[System.Net.Http.HttpClient]')) {
                Assert-True (-not $content.Contains($cmd)) "Direct HTTP is not permitted in $($file.Name)"
            }
        }
    }
}

Invoke-TestCase -Name 'All source modules have at least one direct test reference' -Body {
    # Inventory check only; NOT a line-coverage percentage.
    $testText = (@(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'tests') -Recurse -Filter '*.Tests.ps1' -File |
        ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join [Environment]::NewLine)
    foreach ($module in @('Configuration.psm1','Logging.psm1','Logging.File.ps1','Dispatcher.psm1','UiState.psm1','MainForm.psm1','VcdApi.psm1')) {
        Assert-True ($testText.Contains($module)) "Missing direct test for $module"
    }
}


Invoke-TestCase -Name 'All declared PowerShell functions use Microsoft-approved verbs' -Body {
    $approved = @((Get-Verb).Verb)
    $files = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    foreach ($file in $files) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($function in @($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true))) {
            $verb = ($function.Name -split '-', 2)[0]
            Assert-True ($verb -cin $approved) "Unapproved verb '$verb' in $($file.Name): $($function.Name)"
        }
    }
}

Invoke-TestCase -Name 'WinForms event handlers capture cross-module commands explicitly' -Body {
    $file = Join-Path $ProjectRoot 'src\Presentation\WinForms\MainForm.psm1'
    $content = [IO.File]::ReadAllText($file)
    foreach ($command in @('Start-BackgroundOperation', 'Set-UiOperationStarted', 'Update-UiOperationState', 'Write-AppLog')) {
        Assert-True ($content.Contains("Get-Command -Name '$command'")) "Missing captured command: $command"
    }
    Assert-True ($content.Contains("$" + 'events.Name = ' + "'EventsTextBox'")) 'UI event textbox must have a stable control name'
}

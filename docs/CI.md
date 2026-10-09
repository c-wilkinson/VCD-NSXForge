# NUnit 3 test reporting in CI

This repository writes NUnit 3 XML without installing any external
PowerShell modules. Use a **Windows agent with Windows PowerShell 5.1**, and
execute the test command from the repository root.

## Azure DevOps

```yaml
pool:
  vmImage: windows-latest
steps:
- powershell: |
    & powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -NUnitPath .\test-results\TEST-VcdNetworkManager.xml
    exit $LASTEXITCODE
  displayName: Run native PowerShell tests
- task: PublishTestResults@2
  condition: succeededOrFailed()
  inputs:
    testResultsFormat: NUnit
    testResultsFiles: '**/TEST-VcdNetworkManager.xml'
    searchFolder: '$(System.DefaultWorkingDirectory)'
    mergeTestResults: true
    failTaskOnFailedTests: true
```

This uses ADO's native NUnit result reader. `-IncludeUi` is an **opt-in**
interactive desktop test and should not be used on a headless CI agent.

## GitHub Actions

```yaml
name: PowerShell tests
on: [push, pull_request]
jobs:
  test:
    runs-on: windows-latest
    steps:
    - uses: actions/checkout@v4
    - name: Run tests
      shell: powershell
      run: |
        & powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -NUnitPath .\test-results\TEST-VcdNetworkManager.xml
        exit $LASTEXITCODE
    - name: Retain NUnit results
      if: always()
      uses: actions/upload-artifact@v4
      with:
        name: NUnit-results
        path: test-results/TEST-VcdNetworkManager.xml
        if-no-files-found: error
```

GitHub Actions can upload the NUnit report as an artifact. To display
individual NUnit test results as check annotations or a test tab, configure
an **NUnit 3-compatible reporting action** later, according to your security
policy (this is separate from PowerShell module dependencies). GitHub Actions
does not automatically render uploaded NUnit XML as a test summary.

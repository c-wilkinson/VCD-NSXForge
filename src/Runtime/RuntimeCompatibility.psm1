# Runtime compatibility checks. No policy modification, code execution bypasses or
# allow-rule changes are performed here. The UI and runspace probes are local only.
Set-StrictMode -Version Latest

function Get-RuntimeCompatibilityAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Major,
        [Parameter(Mandatory)][int]$Minor,
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][string]$LanguageMode,
        [Parameter(Mandatory)][string]$ApartmentState,
        [string]$EffectiveExecutionPolicy = 'Unknown',
        [System.Collections.IDictionary]$CapabilityResults = @{}
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Major -ne 5 -or $Minor -ne 1 -or $Edition -ne 'Desktop') {
        $reasons.Add('Windows PowerShell 5.1 Desktop is required (powershell.exe, not pwsh.exe).')
    }
    if ($LanguageMode -ne 'FullLanguage') {
        $reasons.Add("PowerShell language mode '$LanguageMode' is unsupported: WinForms and runspace/.NET calls require FullLanguage. Request an approved, policy-trusted host or deployment from security; do not bypass CLM.")
    }
    if ($ApartmentState -ne 'STA') {
        $reasons.Add('A single-threaded apartment (STA) is required for WinForms. Use the approved powershell.exe -STA launcher.')
    }
    if ($EffectiveExecutionPolicy -eq 'Restricted') {
        $reasons.Add('The effective execution policy is Restricted. Obtain the organisation-approved policy/signing arrangement; do not override execution policy.')
    }
    foreach ($check in @('ModuleImport', 'WorkerRunspace', 'WinFormsConstruction')) {
        if ($CapabilityResults.Contains($check) -and [string]$CapabilityResults[$check] -eq 'Blocked') {
            $reasons.Add("$check was denied or failed. Seek approved host/policy remediation; do not relax application control.")
        }
    }
    [pscustomobject]@{
        SupportedForStartup = ($reasons.Count -eq 0)
        Status = if ($reasons.Count) { 'Blocked' } else { 'RequiresHostValidation' }
        Reasons = @($reasons.ToArray())
        ExecutionPolicyIsSecurityBoundary = $false
        PolicyControlsVerified = $false
        HostEvidenceRequired = @('AppLocker effective enforcement and event evidence', 'WDAC/App Control for Business effective enforcement and event evidence', 'Approved signing/trust and identity context', 'End-to-end WinForms and background-operation smoke test')
    }
}

function Get-RuntimeCompatibilityReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationRoot,
        [switch]$ProbeCapabilities,
        [switch]$ProbeWinForms
    )
    # Nothing that uses arbitrary .NET types or runspaces occurs before this
    # language-mode gate. The standalone diagnostic script has the same gate.
    $mode = [string]$ExecutionContext.SessionState.LanguageMode
    if ($mode -ne 'FullLanguage') {
        throw "VCD-NSXForge cannot operate in $mode. Obtain an approved FullLanguage host; do not disable or bypass application control."
    }
    $ApplicationRoot = [IO.Path]::GetFullPath($ApplicationRoot)
    $effective = 'Unknown'
    $policyScopes = [ordered]@{}
    try { $effective = [string](Get-ExecutionPolicy -ErrorAction Stop) }
    catch { $effective = 'Unavailable' }
    foreach ($scope in @('MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser', 'LocalMachine')) {
        try { $policyScopes[$scope] = [string](Get-ExecutionPolicy -Scope $scope -ErrorAction Stop) }
        catch { $policyScopes[$scope] = 'Unavailable' }
    }
    $apartment = [string][System.Threading.Thread]::CurrentThread.GetApartmentState()
    $assessment = Get-RuntimeCompatibilityAssessment -Major $PSVersionTable.PSVersion.Major -Minor $PSVersionTable.PSVersion.Minor -Edition ([string]$PSVersionTable.PSEdition) -LanguageMode $mode -ApartmentState $apartment -EffectiveExecutionPolicy $effective
    $scriptFile = Join-Path $ApplicationRoot 'Start-VcdNetworkManager.ps1'
    $signature = 'Unavailable'
    try { $signature = [string](Get-AuthenticodeSignature -LiteralPath $scriptFile -ErrorAction Stop).Status }
    catch { $signature = 'Unavailable' }

    $capabilities = [ordered]@{
        ModuleImport = 'NotRun'
        WorkerRunspace = 'NotRun'
        WinFormsConstruction = 'NotRun'
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($assessment.SupportedForStartup -and $ProbeCapabilities) {
        $module = $null
        $modulePath = Join-Path $ApplicationRoot 'src\Runtime\WorkerOperations.psm1'
        $previouslyLoaded = @(Get-Module | Where-Object { $_.Path -eq $modulePath }).Count -gt 0
        try {
            if ($previouslyLoaded) {
                $capabilities.ModuleImport = 'Passed'
            }
            else {
                $module = Import-Module $modulePath -PassThru -ErrorAction Stop
                if ($null -eq $module) { throw 'Module returned no module information.' }
                $capabilities.ModuleImport = 'Passed'
            }
        }
        catch {
            $capabilities.ModuleImport = 'Blocked'
            $problems.Add('Module import failed or was denied by application control. Review policy event logs with security.')
        }
        finally {
            if ($null -ne $module) { Remove-Module -ModuleInfo $module -ErrorAction SilentlyContinue }
        }

        $pool = $null
        $pipeline = $null
        try {
            $pool = [runspacefactory]::CreateRunspacePool(1,1)
            $pool.Open()
            $pipeline = [powershell]::Create()
            $pipeline.RunspacePool = $pool
            # The worker's own language mode must also be FullLanguage. An
            # interactive host's language mode does not certify child runspaces.
            $null = $pipeline.AddScript('$ExecutionContext.SessionState.LanguageMode')
            $output = @($pipeline.Invoke())
            if ($pipeline.HadErrors -or $output.Count -ne 1 -or [string]$output[0] -ne 'FullLanguage') {
                throw 'Background runspace does not have the required FullLanguage capability.'
            }
            $capabilities.WorkerRunspace = 'Passed'
        }
        catch {
            $capabilities.WorkerRunspace = 'Blocked'
            $problems.Add('Background runspace creation or execution failed. Review application-control events with security.')
        }
        finally {
            if ($null -ne $pipeline) { $pipeline.Dispose() }
            if ($null -ne $pool) { try { $pool.Close() } catch { } ; try { $pool.Dispose() } catch { } }
        }

        if ($ProbeWinForms) {
            $form = $null
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                $form = [System.Windows.Forms.Form]::new()
                $form.Text = 'VCD-NSXForge compatibility probe'
                $capabilities.WinFormsConstruction = 'Passed'
            }
            catch {
                $capabilities.WinFormsConstruction = 'Blocked'
                $problems.Add('WinForms construction failed or was denied. Use an approved interactive STA Windows host.')
            }
            finally { if ($null -ne $form) { $form.Dispose() } }
        }
    }

    $ready = ($assessment.SupportedForStartup -and $ProbeCapabilities -and $problems.Count -eq 0)
    $status = if (-not $assessment.SupportedForStartup -or $problems.Count -gt 0) { 'Blocked' }
              elseif (-not $ProbeCapabilities) { 'NotTested' }
              else { 'RequiresHostValidation' }
    [pscustomobject]@{
        ReportSchemaVersion = 1
        Product = 'VCD-NSXForge'
        CapturedUtc = [datetime]::UtcNow.ToString('o')
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        Edition = [string]$PSVersionTable.PSEdition
        LanguageMode = $mode
        ApartmentState = $apartment
        ExecutionPolicy = $effective
        ExecutionPolicyScopes = [pscustomobject]$policyScopes
        EntryScriptSignatureStatus = $signature
        Capabilities = [pscustomobject]$capabilities
        StartupReady = $ready
        Status = $status
        Findings = @($assessment.Reasons) + @($problems.ToArray())
        AppLockerEnforcement = 'NotVerified'
        WdacEnforcement = 'NotVerified'
        SignedCodeTrust = 'NotVerified'
        EnterpriseCompatibilityCertified = $false
        HostEvidenceRequired = @($assessment.HostEvidenceRequired)
    }
}

function Test-RuntimeCompatibilityStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApplicationRoot)
    $report = Get-RuntimeCompatibilityReport -ApplicationRoot $ApplicationRoot -ProbeCapabilities -ProbeWinForms
    if (-not $report.StartupReady) {
        throw ('VCD-NSXForge startup blocked: ' + ($report.Findings -join ' '))
    }
    return $report
}

Export-ModuleMember -Function Get-RuntimeCompatibilityAssessment, Get-RuntimeCompatibilityReport, Test-RuntimeCompatibilityStartup

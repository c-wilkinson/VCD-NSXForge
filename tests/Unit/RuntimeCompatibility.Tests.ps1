Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\src\Runtime\RuntimeCompatibility.psm1') -ErrorAction Stop

Invoke-TestCase -Name 'PowerShell 5.1 Desktop FullLanguage STA passes the local preflight decision but is not policy-certified' -Body {
    $r = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode FullLanguage -ApartmentState STA -EffectiveExecutionPolicy RemoteSigned
    Assert-True $r.SupportedForStartup
    Assert-Equal 'RequiresHostValidation' $r.Status
    Assert-True (-not $r.PolicyControlsVerified)
    Assert-True (-not $r.ExecutionPolicyIsSecurityBoundary)
    Assert-Equal 4 @($r.HostEvidenceRequired).Count
}

Invoke-TestCase -Name 'CLM fails closed even on an otherwise valid Windows PowerShell host' -Body {
    $r = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode ConstrainedLanguage -ApartmentState STA
    Assert-True (-not $r.SupportedForStartup)
    Assert-Equal 'Blocked' $r.Status
    Assert-True (@($r.Reasons | Where-Object { $_ -match 'WinForms|CLM' }).Count -gt 0)
}

Invoke-TestCase -Name 'NoLanguage and RestrictedLanguage fail before any workers are created' -Body {
    foreach ($mode in @('NoLanguage', 'RestrictedLanguage')) {
        $r = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode $mode -ApartmentState STA
        Assert-True (-not $r.SupportedForStartup) "Unexpected compatible result for $mode"
    }
}

Invoke-TestCase -Name 'PowerShell 7 and old Windows PowerShell versions are rejected' -Body {
    foreach ($version in @(@(7, 4, 'Core'), @(5, 0, 'Desktop'), @(4, 0, 'Desktop'))) {
        $r = Get-RuntimeCompatibilityAssessment -Major $version[0] -Minor $version[1] -Edition $version[2] -LanguageMode FullLanguage -ApartmentState STA
        Assert-True (-not $r.SupportedForStartup)
    }
}

Invoke-TestCase -Name 'MTA and execution policy Restricted both block GUI startup' -Body {
    $mta = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode FullLanguage -ApartmentState MTA
    $restricted = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode FullLanguage -ApartmentState STA -EffectiveExecutionPolicy Restricted
    Assert-True (-not $mta.SupportedForStartup)
    Assert-True (-not $restricted.SupportedForStartup)
    Assert-True (@($restricted.Reasons | Where-Object { $_ -match 'approved' }).Count -gt 0)
}

Invoke-TestCase -Name 'Denied module import, worker and WinForms probes fail closed in simulated policy matrix' -Body {
    foreach ($capability in @('ModuleImport', 'WorkerRunspace', 'WinFormsConstruction')) {
        $results = @{}
        $results[$capability] = 'Blocked'
        $r = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode FullLanguage -ApartmentState STA -CapabilityResults $results
        Assert-True (-not $r.SupportedForStartup) "A blocked $capability probe was accepted"
        Assert-True (@($r.Reasons | Where-Object { $_ -match [regex]::Escape($capability) }).Count -gt 0)
    }
}

Invoke-TestCase -Name 'Execution policy Bypass does not claim application-control trust or certification' -Body {
    $r = Get-RuntimeCompatibilityAssessment -Major 5 -Minor 1 -Edition Desktop -LanguageMode FullLanguage -ApartmentState STA -EffectiveExecutionPolicy Bypass
    Assert-True $r.SupportedForStartup
    Assert-True (-not $r.PolicyControlsVerified)
}

Invoke-TestCase -Name 'Actual host inventory preserves policy uncertainty and exposes no identity or secrets' -Body {
    $root = Join-Path $PSScriptRoot '..\..'
    $r = Get-RuntimeCompatibilityReport -ApplicationRoot $root
    Assert-Equal 1 $r.ReportSchemaVersion
    Assert-Equal 'NotVerified' $r.AppLockerEnforcement
    Assert-Equal 'NotVerified' $r.WdacEnforcement
    Assert-True (-not $r.EnterpriseCompatibilityCertified)
    Assert-True ($r.PSObject.Properties.Name -notcontains 'UserName')
    Assert-True ($r.PSObject.Properties.Name -notcontains 'ComputerName')
    Assert-Equal 'NotRun' $r.Capabilities.ModuleImport
}

Invoke-TestCase -Name 'Local module and worker probes report pass only after executing real operations' -Body {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
        [string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        return
    }
    $root = Join-Path $PSScriptRoot '..\..'
    $r = Get-RuntimeCompatibilityReport -ApplicationRoot $root -ProbeCapabilities
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        Assert-True $r.StartupReady ('Probe findings: ' + ($r.Findings -join '; '))
        Assert-Equal 'Passed' $r.Capabilities.ModuleImport
        Assert-Equal 'Passed' $r.Capabilities.WorkerRunspace
    }
}

Invoke-TestCase -Name 'Diagnostic entrypoint and GUI launcher contain no policy-bypass switches' -Body {
    $root = Join-Path $PSScriptRoot '..\..'
    foreach ($path in @('Start-VcdNetworkManager.ps1', 'tools\Test-RuntimeCompatibility.ps1', '.github\workflows\powershell-tests.yml')) {
        $content = [IO.File]::ReadAllText((Join-Path $root $path))
        Assert-True ($content -notmatch '(?i)-ExecutionPolicy\s+Bypass|Set-ExecutionPolicy|__PSLockdownPolicy|LanguageMode\s*=') "Policy bypass found in $path"
    }
}

Invoke-TestCase -Name 'Compatibility check precedes UI module loading and worker creation' -Body {
    $root = Join-Path $PSScriptRoot '..\..'
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start-VcdNetworkManager.ps1'))
    $gate = $source.IndexOf('Test-RuntimeCompatibilityStartup')
    $uiImport = $source.IndexOf('MainForm.psm1')
    $pool = $source.IndexOf('New-WorkerDispatcher')
    Assert-True ($gate -gt 0 -and $gate -lt $uiImport -and $uiImport -lt $pool)
}

Invoke-TestCase -Name 'CLM guard executes before prohibited .NET apartment-state inspection' -Body {
    $root = Join-Path $PSScriptRoot '..\..'
    $source = [IO.File]::ReadAllText((Join-Path $root 'Start-VcdNetworkManager.ps1'))
    $modeGuard = $source.IndexOf("SessionState.LanguageMode -ne 'FullLanguage'")
    $dotNet = $source.IndexOf('[System.Threading.Thread]::CurrentThread.GetApartmentState()')
    Assert-True ($modeGuard -gt 0 -and $dotNet -gt $modeGuard)
}

Invoke-TestCase -Name 'Diagnostic script is read-only and does not claim WDAC or AppLocker certification' -Body {
    $root = Join-Path $PSScriptRoot '..\..'
    $file = [IO.File]::ReadAllText((Join-Path $root 'src\Runtime\RuntimeCompatibility.psm1'))
    Assert-True ($file.Contains('EnterpriseCompatibilityCertified = $false'))
    Assert-True ($file.Contains("WdacEnforcement = 'NotVerified'"))
    Assert-True ($file.Contains("AppLockerEnforcement = 'NotVerified'"))
    foreach ($unsafe in @('Set-ExecutionPolicy','Set-AppLockerPolicy','__PSLockdownPolicy','-ExecutionPolicy Bypass')) {
        Assert-True (-not $file.Contains($unsafe)) "Unexpected policy override: $unsafe"
    }
}

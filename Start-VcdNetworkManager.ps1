#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Launch with Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw 'WinForms requires STA. Start with: powershell.exe -NoProfile -STA -File .\Start-VcdNetworkManager.ps1'
}

$root = $PSScriptRoot
Import-Module (Join-Path $root 'src\Application\Configuration\Configuration.psm1') -Force
Import-Module (Join-Path $root 'src\Infrastructure\Logging\Logging.psm1') -Force
Import-Module (Join-Path $root 'src\Runtime\Dispatcher.psm1') -Force
Import-Module (Join-Path $root 'src\Presentation\WinForms\MainForm.psm1') -Force

$config = Read-AppConfiguration -ApplicationRoot $root
$logsPath = Join-Path $root $config.logging.directory
$logger = $null
$dispatcher = $null
$window = $null

try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $logger = Start-AppLogger -ApplicationRoot $root -Directory $logsPath -MaximumBytes $config.logging.maximumFileBytes -RetentionDays $config.logging.retentionDays -MinimumLevel $config.logging.level
    Write-AppLog -Logger $logger -Component 'Bootstrap' -Message 'VCD-NSXForge application started'
    $dispatcher = New-WorkerDispatcher -ApplicationRoot $root -Logger $logger -MaximumWorkers $config.runtime.maximumWorkers
    $window = New-NetworkManagerForm -Configuration $config -Dispatcher $dispatcher -Logger $logger
    [System.Windows.Forms.Application]::Run($window.Form)
}
finally {
    if ($null -ne $window) {
        $window.Timer.Stop()
        $window.Timer.Dispose()
        $window.Form.Dispose()
    }
    if ($null -ne $dispatcher) {
        Close-WorkerDispatcher -Dispatcher $dispatcher
    }
    if ($null -ne $logger) {
        Write-AppLog -Logger $logger -Component 'Bootstrap' -Message 'VCD-NSXForge application stopped'
        Stop-AppLogger -Logger $logger
    }
}

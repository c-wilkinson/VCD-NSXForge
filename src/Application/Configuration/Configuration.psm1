Set-StrictMode -Version Latest

function Read-AppConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApplicationRoot)

    $path = Join-Path $ApplicationRoot 'config\application.json'
    if (-not [IO.File]::Exists($path)) { throw "Configuration not found: $path" }
    $configuration = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($configuration.schemaVersion -ne 1) { throw 'Unsupported configuration schema.' }
    if ($configuration.target.vcdVersion -ne '10.6' -or $configuration.target.networkBacking -ne 'NSX-T') {
        throw 'This project currently supports the VCD 10.6 / NSX-T target only.'
    }
    if ($configuration.target.powershellVersion -ne '5.1') { throw 'Expected Windows PowerShell 5.1.' }
    if ($configuration.runtime.maximumWorkers -lt 1 -or $configuration.runtime.maximumWorkers -gt 8) {
        throw 'maximumWorkers must be between 1 and 8.'
    }
    if ($configuration.runtime.uiPollMilliseconds -lt 50 -or $configuration.runtime.uiPollMilliseconds -gt 1000) {
        throw 'uiPollMilliseconds must be between 50 and 1000.'
    }
    if ($configuration.logging.maximumFileBytes -lt 1024 -or $configuration.logging.maximumFileBytes -gt 5000000) {
        throw 'Log file size must be between 1 KiB and 5 MB.'
    }
    if ($configuration.logging.retentionDays -lt 1 -or $configuration.logging.retentionDays -gt 30) {
        throw 'Log retention must be between 1 and 30 days.'
    }
    if ($configuration.logging.level -notin @('DEBUG','INFO','WARN','ERROR')) {
        throw 'Unsupported log level.'
    }
    if ([IO.Path]::IsPathRooted([string]$configuration.logging.directory)) {
        throw 'Logging directory must be relative to the application root.'
    }
    if (($configuration.logging.directory -split '[\\/]') -contains '..') {
        throw 'Logging directory cannot traverse outside the application root.'
    }

    $configuration | Add-Member -NotePropertyName ApplicationRoot -NotePropertyValue $ApplicationRoot
    $configuration
}

Export-ModuleMember -Function Read-AppConfiguration

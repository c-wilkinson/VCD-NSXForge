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

    if ($configuration.PSObject.Properties.Name -cnotcontains 'state') { throw 'State configuration is missing.' }
    foreach ($setting in @('directory','reportsDirectory','demoDirectory')) {
        $value = [string]$configuration.state.$setting
        if ([string]::IsNullOrWhiteSpace($value) -or [IO.Path]::IsPathRooted($value) -or ($value -split '[\\/]') -contains '..') {
            throw "Unsafe state path setting '$setting'."
        }
    }
    foreach ($setting in @('defaultEnvironment','defaultScope')) {
        $value = [string]$configuration.state.$setting
        if ($value -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') { throw "Invalid state setting '$setting'." }
    }
    # No remote calls are attempted until an administrator supplies a URL and target IDs.
    if ($configuration.PSObject.Properties.Name -cnotcontains 'vcd') { throw 'VCD connection configuration is missing.' }
    $vcd = $configuration.vcd
    $mode = if ($vcd.PSObject.Properties.Name -contains 'mode') { [string]$vcd.mode } else { 'Live' }
    if ($mode -cnotin @('Live','Simulator')) { throw 'vcd.mode must be Live or Simulator.' }
    $address = [string]$vcd.apiUrl
    if ($address) {
        $uri = $null
        if (-not [uri]::TryCreate($address, [System.UriKind]::Absolute, [ref]$uri) -or
            -not [string]::IsNullOrEmpty($uri.UserInfo) -or $uri.AbsolutePath -cne '/' -or $uri.Query -or $uri.Fragment) {
            throw 'vcd.apiUrl must be an origin without path, credentials or query.'
        }
        if ($mode -eq 'Live' -and $uri.Scheme -cne 'https') {
            throw 'Live VCD connections require HTTPS.'
        }
        if ($mode -eq 'Simulator' -and ($uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1')) {
            throw 'Simulator connections require http://127.0.0.1:<port> only.'
        }
    }
    if ($vcd.apiVersion -cne '39.0') { throw 'Phase 3 requires VCD OpenAPI version 39.0.' }
    if ($vcd.loginScope -cnotin @('Tenant','Provider')) { throw 'vcd.loginScope must be Tenant or Provider.' }
    if ($vcd.authentication -cnotin @('Credential','BearerToken')) { throw 'Unsupported VCD authentication setting.' }
    if ($vcd.timeoutSeconds -isnot [int] -or $vcd.timeoutSeconds -lt 5 -or $vcd.timeoutSeconds -gt 180) { throw 'VCD timeoutSeconds must be 5..180.' }
    if ($null -eq $vcd.networkIds -or $vcd.networkIds -isnot [array]) { throw 'vcd.networkIds must be a JSON array.' }
    foreach ($id in @($vcd.networkIds) + @($vcd.gatewayId, $vcd.tenantContextOrgId)) {
        if ($null -eq $id -or $id -eq '') { continue }
        if ($id -isnot [string] -or $id -notmatch '^urn:vcloud:[A-Za-z0-9_-]+:[a-fA-F0-9-]{8,}$') {
            throw 'VCD resource identifiers must be full URNs, not names or arbitrary paths.'
        }
    }
    if (@($vcd.networkIds | Select-Object -Unique).Count -ne @($vcd.networkIds).Count) { throw 'Duplicate VCD network IDs.' }
    $configuration | Add-Member -NotePropertyName ApplicationRoot -NotePropertyValue $ApplicationRoot
    $configuration
}

Export-ModuleMember -Function Read-AppConfiguration

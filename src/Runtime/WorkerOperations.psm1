# Shared read-only/simulator worker operation contract for Windows PowerShell 5.1.
# Definitions are deliberately data-only: no dynamic code loading or network access.
Set-StrictMode -Version Latest

$script:OperationDefinitions = [ordered]@{
    ProgressDemo        = @{ Required = @{}; Optional = @{}; Kind = 'Demo' }
    FailureDemo         = @{ Required = @{}; Optional = @{}; Kind = 'Demo' }
    OfflinePlan         = @{ Required = @{ StateRoot='Text'; Environment='Text'; Scope='Text'; OutputDirectory='Text' }; Optional = @{}; Kind = 'Offline' }
    VcdRead             = @{ Required = @{ VcdConfiguration='Object'; OutputDirectory='Text'; ConnectionOnly='Boolean' }; Optional = @{ Credential='Object'; BearerToken='Text'; DiscoverOnly='Boolean' }; Kind = 'ReadOnly' }
    SimulatorScopes     = @{ Required = @{ ApiUrl='SimulatorOrigin' }; Optional = @{}; Kind = 'Simulator' }
    SimulatorLoadState  = @{ Required = @{ ApiUrl='SimulatorOrigin'; GatewayId='Text' }; Optional = @{}; Kind = 'Simulator' }
    SimulatorPlan       = @{ Required = @{ ApiUrl='SimulatorOrigin'; Baseline='Object'; Documents='Object'; OutputDirectory='Text' }; Optional = @{}; Kind = 'Simulator' }
    SimulatorApply      = @{ Required = @{ ApiUrl='SimulatorOrigin'; Approved='Object'; ActorDomain='Text'; ActorTier='Tier' }; Optional = @{}; Kind = 'Simulator' }
    SimulatorTraffic    = @{ Required = @{ ApiUrl='SimulatorOrigin'; GatewayId='Text'; SourceIp='Text'; DestinationIp='Text'; Protocol='Text'; DestinationPort='Port' }; Optional = @{}; Kind = 'Simulator' }
    SimulatorSaveDraft  = @{ Required = @{ ApiUrl='SimulatorOrigin'; Documents='Object'; StateRoot='Text'; Scope='Text' }; Optional = @{}; Kind = 'Simulator' }
    SaveRuleTemplate    = @{ Required = @{ Rule='Object'; TemplateName='Text'; TemplatePath='Text'; BuiltInPath='Text' }; Optional = @{}; Kind = 'Offline' }
}

function Get-WorkerOperationDefinitions {
    # Return a copy: callers cannot alter the shared registry by reference.
    foreach ($name in @($script:OperationDefinitions.Keys)) {
        $entry = $script:OperationDefinitions[$name]
        [pscustomobject]@{
            Name = $name
            Kind = [string]$entry.Kind
            Required = @($entry.Required.Keys | Sort-Object)
            Optional = @($entry.Optional.Keys | Sort-Object)
            SupportsCancellation = $true
        }
    }
}

function Confirm-WorkerOperationArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Arguments = @{}
    )
    if (-not $script:OperationDefinitions.Contains($Operation)) {
        throw [System.ArgumentException]::new("Unsupported worker operation '$Operation'.")
    }
    if ($null -eq $Arguments) { throw [System.ArgumentException]::new('Operation arguments cannot be null.') }
    $definition = $script:OperationDefinitions[$Operation]
    foreach ($key in @($Arguments.Keys)) {
        if (-not $definition.Required.ContainsKey([string]$key) -and -not $definition.Optional.ContainsKey([string]$key)) {
            throw [System.ArgumentException]::new("$Operation does not accept argument '$key'.")
        }
    }
    foreach ($key in @($definition.Required.Keys)) {
        if (-not $Arguments.ContainsKey($key) -or $null -eq $Arguments[$key]) {
            throw [System.ArgumentException]::new("$Operation requires argument '$key'.")
        }
    }
    foreach ($key in @($Arguments.Keys)) {
        $kind = if ($definition.Required.ContainsKey($key)) { $definition.Required[$key] } else { $definition.Optional[$key] }
        $value = $Arguments[$key]
        if ($null -eq $value) {
            if ($definition.Required.ContainsKey($key)) { throw [System.ArgumentException]::new("$Operation requires non-null '$key'.") }
            continue
        }
        switch ($kind) {
            'Text' {
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                    throw [System.ArgumentException]::new("$Operation requires non-empty text '$key'.")
                }
            }
            'Boolean' {
                if ($value -isnot [bool]) { throw [System.ArgumentException]::new("$Operation requires boolean '$key'.") }
            }
            'Object' {
                if ($value -is [string] -or $value -is [ValueType]) {
                    throw [System.ArgumentException]::new("$Operation requires an object for '$key'.")
                }
            }
            'Tier' {
                if ($value -isnot [int] -or $value -notin @(0,1)) {
                    throw [System.ArgumentException]::new("$Operation requires ActorTier 0 or 1.")
                }
            }
            'Port' {
                if ($value -isnot [int] -or $value -lt 0 -or $value -gt 65535) {
                    throw [System.ArgumentException]::new("$Operation requires DestinationPort in 0..65535.")
                }
            }
            'SimulatorOrigin' {
                $uri = $null
                if ($value -isnot [string] -or
                    -not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
                    $uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1' -or
                    $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                    $uri.AbsolutePath -cne '/' -or $uri.Port -lt 1024) {
                    throw [System.ArgumentException]::new('Simulator operations require an explicit HTTP 127.0.0.1 origin (port >= 1024); live hosts are prohibited.')
                }
            }
        }
    }
    if ($Operation -eq 'VcdRead' -and $Arguments.ContainsKey('Credential') -and $null -ne $Arguments.Credential -and
        $Arguments.ContainsKey('BearerToken') -and $null -ne $Arguments.BearerToken) {
        throw [System.ArgumentException]::new('VcdRead cannot combine Credential with BearerToken.')
    }
}

Export-ModuleMember -Function Get-WorkerOperationDefinitions, Confirm-WorkerOperationArguments

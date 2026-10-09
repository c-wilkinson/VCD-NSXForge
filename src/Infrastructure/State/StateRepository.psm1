# Disk-backed repository: paths, complete-view loading, optimistic writes, atomic replace.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\StateModel.psm1') -Force

$script:DocumentNames = [ordered]@{
    ipSets = 'ip-sets.json'
    edgeFirewallRules = 'firewall-rules.json'
    manualIpReservations = 'ip-reservations.json'
}

function Get-NetworkStateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope,
          [Parameter(Mandatory)][ValidateSet('desired','observed','applied')][string]$View)
    foreach ($segment in @($Environment,$Scope)) {
        if ($segment -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') { throw "Invalid state path segment '$segment'." }
    }
    return [IO.Path]::Combine([IO.Path]::GetFullPath($StateRoot), $Environment, $Scope, $View)
}

function Get-NetworkStateDocumentPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope,
          [Parameter(Mandatory)][ValidateSet('desired','observed','applied')][string]$View,
          [Parameter(Mandatory)][ValidateSet('ipSets','edgeFirewallRules','manualIpReservations')][string]$ResourceKind)
    $dir = Get-NetworkStateDirectory -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View $View
    return (Join-Path $dir $script:DocumentNames[$ResourceKind])
}

function Get-NetworkFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return '' }
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return ([BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant()) }
        finally { $stream.Dispose() }
    }
    finally { $hash.Dispose() }
}

function Read-NetworkStateView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope,
          [Parameter(Mandatory)][ValidateSet('desired','observed','applied')][string]$View)
    $documents = [ordered]@{}
    $filesFound = 0
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $path = Get-NetworkStateDocumentPath -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View $View -ResourceKind $kind
        if (-not [IO.File]::Exists($path)) { continue }
        $filesFound++
        try { $raw = [IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Unable to read state '$path': $($_.Exception.Message)" }
        $doc = ConvertTo-NetworkStateDocument -InputObject $raw
        if ($doc.resourceKind -cne $kind) { throw "State file '$path' identifies wrong resource kind '$($doc.resourceKind)'." }
        $documents[$kind] = $doc
    }
    if ($filesFound -gt 0 -and $filesFound -ne $script:DocumentNames.Count) {
        throw "Incomplete '$View' state under '$Environment/$Scope': all three resource documents must exist."
    }
    return [pscustomobject]@{
        Available = ($filesFound -eq $script:DocumentNames.Count)
        Environment = $Environment
        Scope = $Scope
        View = $View
        Documents = $documents
    }
}

function Save-NetworkStateDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope,
          [Parameter(Mandatory)][ValidateSet('desired','observed','applied')][string]$View,
          [Parameter(Mandatory)]$Document,
          [string]$ExpectedSha256 = '')
    $validated = ConvertTo-NetworkStateDocument -InputObject $Document
    $path = Get-NetworkStateDocumentPath -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View $View -ResourceKind $validated.resourceKind
    $directory = [IO.Path]::GetDirectoryName($path)
    [void][IO.Directory]::CreateDirectory($directory)
    $lock = "$path.lock"
    $guard = $null
    $temp = "$path.$([guid]::NewGuid().ToString('n')).tmp"
    $backup = "$path.$([guid]::NewGuid().ToString('n')).bak"
    $replaced = $false
    try {
        # An exclusive lock file protects the compare-and-swap across processes.
        $guard = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $exists = [IO.File]::Exists($path)
        $current = Get-NetworkFileSha256 -Path $path
        if ($exists -and [string]::IsNullOrWhiteSpace($ExpectedSha256)) { throw "Refusing to overwrite existing state without ExpectedSha256: $path" }
        if ($ExpectedSha256 -and $current -cne $ExpectedSha256.ToLowerInvariant()) { throw "State has changed since it was read: $path" }
        if (-not $exists -and $ExpectedSha256) { throw "State was removed since it was read: $path" }
        $json = ConvertTo-Json -InputObject $validated -Depth 30
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine)
        $output = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $output.Write($bytes,0,$bytes.Length)
            $output.Flush($true)
        }
        finally { $output.Dispose() }
        if ($exists) {
            # Windows PowerShell 5.1 / .NET Framework requires a legal backup
            # path here; passing $null can fail with "The path is not of a legal form".
            # All paths live in the same directory so the replacement is atomic.
            [IO.File]::Replace($temp, $path, $backup)
            $replaced = $true
        }
        else { [IO.File]::Move($temp, $path) }
        return [pscustomobject]@{ Path = $path; Sha256 = (Get-NetworkFileSha256 -Path $path); Bytes = $bytes.Length }
    }
    finally {
        if ($null -ne $guard) {
            $guard.Dispose()
            if ([IO.File]::Exists($lock)) { [IO.File]::Delete($lock) }
        }
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        # Preserve a recovery copy if replacement failed; clean it up only
        # after File.Replace reported success.
        if ($replaced -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function Initialize-NetworkDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope)
    $directory = Get-NetworkStateDirectory -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View 'desired'
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $path = Get-NetworkStateDocumentPath -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View 'desired' -ResourceKind $kind
        if ([IO.File]::Exists($path)) { throw "Refusing to initialise over existing desired state: $path" }
    }
    foreach ($kind in @(Get-NetworkResourceKinds)) {
        $doc = New-EmptyNetworkDocument -ResourceKind $kind
        $null = Save-NetworkStateDocument -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View 'desired' -Document $doc
    }
    return $directory
}

Export-ModuleMember -Function Get-NetworkStateDirectory, Get-NetworkStateDocumentPath, Get-NetworkFileSha256, Read-NetworkStateView, Save-NetworkStateDocument, Initialize-NetworkDesiredState

# Independent v3 observed-policy store. Never overwrites v2 desired/applied/observed.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\State\VcdPolicyModel.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'StateRepository.psm1') -Force

function Get-VcdPolicyObservedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope)
    # Reuse the strict, traversal-safe environment/scope validation.
    $observed = Get-NetworkStateDirectory -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View observed
    return (Join-Path ([IO.Path]::GetDirectoryName($observed)) 'vcd-policy-observed.json')
}

function Read-VcdPolicyObserved {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope)
    $path = Get-VcdPolicyObservedPath -StateRoot $StateRoot -Environment $Environment -Scope $Scope
    if (-not [IO.File]::Exists($path)) {
        return [pscustomobject]@{ Available=$false; Path=$path; Document=$null; Sha256='' }
    }
    try {
        $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -ErrorAction Stop
        $null = Confirm-VcdPolicyDocument -Document $document
    }
    catch { throw "Invalid VCD policy at '$path': $($_.Exception.Message)" }
    return [pscustomobject]@{
        Available=$true; Path=$path; Document=$document
        Sha256=(Get-NetworkFileSha256 -Path $path)
    }
}

function Save-VcdPolicyObserved {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope,
          [Parameter(Mandatory)]$Document,
          [string]$ExpectedSha256 = '')
    $null = Confirm-VcdPolicyDocument -Document $Document
    $path = Get-VcdPolicyObservedPath -StateRoot $StateRoot -Environment $Environment -Scope $Scope
    $directory = [IO.Path]::GetDirectoryName($path)
    [void][IO.Directory]::CreateDirectory($directory)
    $lockPath = "$path.lock"
    $temp = "$path.$([guid]::NewGuid().ToString('n')).tmp"
    $backup = "$path.$([guid]::NewGuid().ToString('n')).bak"
    $guard = $null
    $replaced = $false
    try {
        $guard = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $exists = [IO.File]::Exists($path)
        if ($exists) {
            $currentHash = Get-NetworkFileSha256 -Path $path
            if ($ExpectedSha256 -and $ExpectedSha256 -cne $currentHash) { throw 'Observed VCD policy changed since last read.' }
            # Refuse to overwrite corrupt or unknown schema data, even when no hash supplied.
            $null = Read-VcdPolicyObserved -StateRoot $StateRoot -Environment $Environment -Scope $Scope
        }
        elseif ($ExpectedSha256) { throw 'Observed VCD policy disappeared since last read.' }
        $json = ConvertTo-Json -InputObject $Document -Depth 100
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine)
        $stream = [IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ($exists) {
            [IO.File]::Replace($temp, $path, $backup)
            $replaced = $true
        }
        else { [IO.File]::Move($temp, $path) }
        return [pscustomobject]@{ Path=$path; Sha256=(Get-NetworkFileSha256 -Path $path) }
    }
    finally {
        if ($null -ne $guard) {
            $guard.Dispose()
            if ([IO.File]::Exists($lockPath)) { [IO.File]::Delete($lockPath) }
        }
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ($replaced -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

Export-ModuleMember -Function Get-VcdPolicyObservedPath, Read-VcdPolicyObserved, Save-VcdPolicyObserved

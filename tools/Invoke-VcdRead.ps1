#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Credential')]
param(
    [switch]$ConnectionOnly,
    [switch]$CapabilitiesOnly,
    [switch]$WriteObserved,
    [string]$Environment = '',
    [string]$Scope = '',
    [Parameter(ParameterSetName='Credential')][pscredential]$Credential,
    [Parameter(ParameterSetName='Token')][securestring]$BearerToken
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'src\Application\Configuration\Configuration.psm1') -Force
Import-Module (Join-Path $root 'src\Application\VcdRead\VcdReadOperation.psm1') -Force
$cfg = Read-AppConfiguration -ApplicationRoot $root
if (-not $Environment) { $Environment = [string]$cfg.state.defaultEnvironment }
if (-not $Scope) { $Scope = [string]$cfg.state.defaultScope }
$params = @{
    VcdConfiguration = $cfg.vcd
    OutputDirectory = (Join-Path $root $cfg.state.reportsDirectory)
    StateRoot = (Join-Path $root $cfg.state.directory)
    Environment = $Environment
    Scope = $Scope
    ConnectionOnly = $ConnectionOnly
    CapabilitiesOnly = $CapabilitiesOnly
    WriteObserved = $WriteObserved
}
if ($cfg.vcd.PSObject.Properties.Name -contains 'mode' -and $cfg.vcd.mode -eq 'Simulator') {
    if ($PSBoundParameters.ContainsKey('Credential') -or $PSBoundParameters.ContainsKey('BearerToken')) { throw 'Simulator mode must not receive real credentials or bearer tokens.' }
}
elseif ($PSCmdlet.ParameterSetName -eq 'Token') {
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($BearerToken)
        $params.BearerToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}
else {
    if (-not $Credential) { $Credential = Get-Credential -Message 'Enter VCD username@org and password' }
    if (-not $Credential) { throw 'Credential prompt was cancelled.' }
    $params.Credential = $Credential
}
$result = Invoke-VcdReadOperation @params
if ($CapabilitiesOnly) {
    # Pure stdout report: no remote mutations or local state/report writes.
    $result.Capability | ConvertTo-Json -Depth 40
} else {
    $result | Format-List
}

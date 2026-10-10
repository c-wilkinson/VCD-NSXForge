# Simulator-only HTTP client. No production VCD request path or real credentials.
Set-StrictMode -Version Latest

function Confirm-SimulatorOrigin {
    param([Parameter(Mandatory)][string]$ApiUrl)
    $uri=$null
    if (-not [uri]::TryCreate($ApiUrl,[UriKind]::Absolute,[ref]$uri) -or
        $uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1' -or $uri.UserInfo -or
        $uri.AbsolutePath -cne '/' -or $uri.Query -or $uri.Fragment -or $uri.Port -lt 1024) {
        throw 'Simulator writes require explicit HTTP 127.0.0.1 origin; live VCD and other hosts are prohibited.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Invoke-SimulatorApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiUrl,
          [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
          [Parameter(Mandatory)][ValidateSet('scopes','state','apply','traffic')][string]$Resource,
          [string]$GatewayId='', $Payload,
          [System.Threading.CancellationToken]$CancellationToken=[System.Threading.CancellationToken]::None)
    $origin=Confirm-SimulatorOrigin -ApiUrl $ApiUrl
    $CancellationToken.ThrowIfCancellationRequested()
    if ($Method -eq 'POST' -and $Resource -notin @('apply','traffic')) { throw 'Invalid simulator write endpoint.' }
    if ($Method -eq 'GET' -and $Resource -eq 'apply') { throw 'Apply requires POST.' }
    if ($Resource -in @('state','traffic') -and $Method -eq 'GET' -and -not $GatewayId) { throw 'A gateway ID is required.' }
    $url="$origin/__simulator/v1/$Resource"
    if ($Method -eq 'GET' -and $GatewayId) { $url+='?gatewayId='+[uri]::EscapeDataString($GatewayId) }
    $headers=@{Authorization= $(if ($Method -eq 'POST') {'Bearer simulator-edit-only'} else {'Bearer simulator-read-only'}) }
    $arguments=@{Uri=$url;Method=$Method;Headers=$headers;TimeoutSec=20;ErrorAction='Stop';MaximumRedirection=0}
    if ($Method -eq 'POST') {
        if ($null -eq $Payload) { throw 'POST requires a JSON payload.' }
        $arguments.ContentType='application/json'
        $arguments.Body=ConvertTo-Json -InputObject $Payload -Depth 40 -Compress
    }
    $response=Invoke-RestMethod @arguments
    if ($Resource -eq 'state' -and $Method -eq 'GET') {
        $docs=[ordered]@{}
        foreach ($kind in @('ipSets','edgeFirewallRules','manualIpReservations')) {
            $docs[$kind]=$response.documents.$kind
        }
        $response.documents=$docs
    }
    $CancellationToken.ThrowIfCancellationRequested()
    return $response
}

Export-ModuleMember -Function Confirm-SimulatorOrigin, Invoke-SimulatorApi

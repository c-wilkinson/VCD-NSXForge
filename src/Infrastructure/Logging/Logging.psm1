Set-StrictMode -Version Latest

function Start-AppLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationRoot,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateRange(1024,5000000)][int]$MaximumBytes,
        [Parameter(Mandatory)][ValidateRange(1,30)][int]$RetentionDays,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$MinimumLevel = 'INFO'
    )
    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $errors = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $signal = [System.Threading.ManualResetEventSlim]::new($false)
    $stopSource = [System.Threading.CancellationTokenSource]::new()
    $pool = [runspacefactory]::CreateRunspacePool(1,1)
    $pool.Open()
    $pipeline = [powershell]::Create()
    $pipeline.RunspacePool = $pool
    $script = [IO.File]::ReadAllText((Join-Path $ApplicationRoot 'src\Infrastructure\Logging\Logging.Writer.ps1'))
    $null = $pipeline.AddScript($script).AddArgument($queue).AddArgument($signal).AddArgument($stopSource).AddArgument($errors).AddArgument($ApplicationRoot).AddArgument($Directory).AddArgument($MaximumBytes).AddArgument($RetentionDays)
    $handle = $pipeline.BeginInvoke()
    return [pscustomobject]@{
        Queue = $queue
        Errors = $errors
        Signal = $signal
        StopSource = $stopSource
        Pool = $pool
        Pipeline = $pipeline
        Handle = $handle
        MinimumLevel = $MinimumLevel
    }
}

function Protect-AppLogText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    # Defence in depth only. Do not pass untrusted request/response bodies to logs.
    $safe = [regex]::Replace($Text, '(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', '$1 [REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)\b(password|passwd|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|authorization|x-vmware-vcloud-access-token)\b(\s*[=:]\s*|["'']\s*:\s*["''])[^\s,;"''}]+', '$1=[REDACTED]')
    return $safe
}

function Protect-AppLogProperties {
    param([hashtable]$Values)
    $safe = @{}
    foreach ($key in $Values.Keys) {
        $name = [string]$key
        if ($name -match '(?i)password|token|credential|secret|authorization|api.?key|cookie|header') {
            $safe[$name] = '[REDACTED]'
        }
        elseif ($Values[$key] -is [pscredential] -or $Values[$key] -is [securestring]) {
            $safe[$name] = '[REDACTED]'
        }
        elseif ($Values[$key] -is [hashtable]) {
            $safe[$name] = Protect-AppLogProperties -Values $Values[$key]
        }
        elseif ($Values[$key] -is [string]) {
            $safe[$name] = Protect-AppLogText -Text ([string]$Values[$key])
        }
        elseif ($null -eq $Values[$key] -or $Values[$key] -is [ValueType]) {
            $safe[$name] = $Values[$key]
        }
        else {
            # Object graphs may contain non-obvious private fields. Do not serialize them.
            $safe[$name] = '[OBJECT OMITTED]'
        }
    }
    return $safe
}

function Write-AppLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Logger,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Message,
        [string]$OperationId = '',
        [hashtable]$Properties = @{}
    )
    $levelValue = @{ DEBUG = 10; INFO = 20; WARN = 30; ERROR = 40 }
    if ($levelValue[$Level] -lt $levelValue[[string]$Logger.MinimumLevel]) { return }
    # Only explicit safe metadata is accepted here. Do not pass credentials, raw HTTP bodies or tokens.
    $record = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        level = $Level
        component = Protect-AppLogText -Text $Component
        operationId = Protect-AppLogText -Text $OperationId
        message = Protect-AppLogText -Text $Message
        properties = Protect-AppLogProperties -Values $Properties
    }
    $Logger.Queue.Enqueue($record)
    $Logger.Signal.Set()
}

function Stop-AppLogger {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Logger, [int]$TimeoutMilliseconds = 5000)
    $Logger.StopSource.Cancel()
    $Logger.Signal.Set()
    try {
        if (-not $Logger.Handle.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            throw 'Log writer did not finish within the shutdown timeout.'
        }
        $null = $Logger.Pipeline.EndInvoke($Logger.Handle)
    }
    finally {
        $Logger.Pipeline.Dispose()
        $Logger.Pool.Dispose()
        $Logger.StopSource.Dispose()
        $Logger.Signal.Dispose()
    }
}

Export-ModuleMember -Function Start-AppLogger, Write-AppLog, Stop-AppLogger, Protect-AppLogText

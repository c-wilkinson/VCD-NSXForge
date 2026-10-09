# Pure file operations for the single log-writer runspace. Can be tested without WinForms.
Set-StrictMode -Version Latest

function New-LogFileSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateRange(256, 5000000)][int]$MaximumBytes
    )
    [void][IO.Directory]::CreateDirectory($Directory)
    $session = [pscustomobject]@{
        Directory = [IO.Path]::GetFullPath($Directory)
        ActivePath = [IO.Path]::Combine([IO.Path]::GetFullPath($Directory), 'network-manager.log')
        MaximumBytes = $MaximumBytes
        ActiveUtcDate = [DateTime]::UtcNow.Date
        Writer = $null
    }
    if ([IO.File]::Exists($session.ActivePath)) {
        $active = [IO.FileInfo]::new($session.ActivePath)
        if ($active.Length -ge $MaximumBytes -or $active.LastWriteTimeUtc.Date -lt $session.ActiveUtcDate) {
            Move-ActiveLogFile -Session $session
        }
    }
    Open-ActiveLogFile -Session $session
    return $session
}

function Open-ActiveLogFile {
    param([Parameter(Mandatory)]$Session)
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $Session.Writer = [IO.StreamWriter]::new($Session.ActivePath, $true, $utf8)
    $Session.Writer.AutoFlush = $true
}

function Move-ActiveLogFile {
    param([Parameter(Mandatory)]$Session)
    if ($null -ne $Session.Writer) {
        $Session.Writer.Flush()
        $Session.Writer.Dispose()
        $Session.Writer = $null
    }
    if (-not [IO.File]::Exists($Session.ActivePath)) { return }
    if (([IO.FileInfo]$Session.ActivePath).Length -eq 0) {
        [IO.File]::Delete($Session.ActivePath)
        return
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    for ($number = 0; $number -lt 100000; $number++) {
        $archived = [IO.Path]::Combine($Session.Directory,
            ('network-manager.{0}.{1:D5}.log' -f $stamp, $number))
        if (-not [IO.File]::Exists($archived)) {
            [IO.File]::Move($Session.ActivePath, $archived)
            return
        }
    }
    throw 'Unable to allocate a unique rotated log filename.'
}

function Write-LogFileRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Record)

    # Single-line records are bounded; do not split or silently exceed the configured size.
    $serialized = ConvertTo-Json -InputObject $Record -Compress -Depth 10
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $newline = [Environment]::NewLine
    $byteCount = $encoding.GetByteCount($serialized + $newline)
    if ($byteCount -gt $Session.MaximumBytes) {
        $serialized = ConvertTo-Json -Compress -InputObject ([ordered]@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            level = 'ERROR'
            component = 'Logging'
            message = 'Oversized record omitted'
        })
        $byteCount = $encoding.GetByteCount($serialized + $newline)
        if ($byteCount -gt $Session.MaximumBytes) { throw 'Maximum log size cannot contain minimum record.' }
    }
    if ($Session.ActiveUtcDate -lt [DateTime]::UtcNow.Date) {
        Move-ActiveLogFile -Session $Session
        $Session.ActiveUtcDate = [DateTime]::UtcNow.Date
        Open-ActiveLogFile -Session $Session
    }
    if (($Session.Writer.BaseStream.Length + $byteCount) -gt $Session.MaximumBytes) {
        Move-ActiveLogFile -Session $Session
        Open-ActiveLogFile -Session $Session
    }
    $Session.Writer.WriteLine($serialized)
}

function Invoke-DailyLogRollover {
    param([Parameter(Mandatory)]$Session)
    if ($Session.ActiveUtcDate -lt [DateTime]::UtcNow.Date) {
        Move-ActiveLogFile -Session $Session
        $Session.ActiveUtcDate = [DateTime]::UtcNow.Date
        Open-ActiveLogFile -Session $Session
    }
}

function Remove-ExpiredLogFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateRange(1,30)][int]$RetentionDays,
        [DateTime]$UtcNow = [DateTime]::UtcNow
    )
    if (-not [IO.Directory]::Exists($Directory)) { return }
    $cutoff = $UtcNow.ToUniversalTime().AddDays(-$RetentionDays)
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter 'network-manager.*.log' -File)) {
        if ($file.LastWriteTimeUtc -lt $cutoff) {
            [IO.File]::Delete($file.FullName)
        }
    }
}

function Close-LogFileSession {
    param([Parameter(Mandatory)]$Session)
    if ($null -ne $Session.Writer) {
        $Session.Writer.Flush()
        $Session.Writer.Dispose()
        $Session.Writer = $null
    }
}

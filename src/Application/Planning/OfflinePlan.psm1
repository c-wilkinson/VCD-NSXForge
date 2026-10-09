# Orchestrates repository -> pure plan -> escaped reports. No VCD calls.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\Infrastructure\State\StateRepository.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Domain\Planning\Planning.psm1') -Force

function Get-OfflineNetworkPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,
          [Parameter(Mandatory)][string]$Environment,
          [Parameter(Mandatory)][string]$Scope)
    $desired = Read-NetworkStateView -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View 'desired'
    if (-not $desired.Available) { throw "Desired state not found for '$Environment/$Scope'. Initialise it first." }
    $applied = Read-NetworkStateView -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View 'applied'
    $observed = Read-NetworkStateView -StateRoot $StateRoot -Environment $Environment -Scope $Scope -View 'observed'
    return (New-NetworkChangePlan -Desired $desired -Applied $applied -Observed $observed -Environment $Environment -Scope $Scope)
}

function Export-OfflineNetworkPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,
          [Parameter(Mandatory)][string]$OutputDirectory,
          [string]$BaseName = '')
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
    if (-not $BaseName) { $BaseName = ('network-plan-{0}-{1}-{2}' -f $Plan.environment,$Plan.scope,[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')) }
    if ($BaseName -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,180}$') { throw 'Invalid report base name.' }
    $jsonPath = Join-Path $OutputDirectory ($BaseName + '.json')
    $htmlPath = Join-Path $OutputDirectory ($BaseName + '.html')
    $json = ConvertTo-Json -InputObject $Plan -Depth 30
    [IO.File]::WriteAllText($jsonPath, $json, [System.Text.UTF8Encoding]::new($false))
    $encode = { param($text) [System.Net.WebUtility]::HtmlEncode([string]$text) }
    $rows = [System.Text.StringBuilder]::new()
    foreach ($action in @($Plan.actions)) {
        $beforeText = if ($null -eq $action.Before) { '' } else { ConvertTo-Json -InputObject $action.Before -Depth 15 }
        $afterText = if ($null -eq $action.After) { '' } else { ConvertTo-Json -InputObject $action.After -Depth 15 }
        # Display human-readable names explicitly, not only in the JSON dump.
        # The JSON serializer can escape certain characters differently across
        # PowerShell versions, whereas HTML encoding is required for HTML text.
        $beforeName = ''
        $afterName = ''
        if ($null -ne $action.Before -and $null -ne $action.Before.PSObject.Properties['name']) {
            $beforeName = [string]$action.Before.name
        }
        if ($null -ne $action.After -and $null -ne $action.After.PSObject.Properties['name']) {
            $afterName = [string]$action.After.name
        }
        $beforeHeading = if ($beforeName) { '<strong>{0}</strong>' -f (& $encode $beforeName) } else { '' }
        $afterHeading = if ($afterName) { '<strong>{0}</strong>' -f (& $encode $afterName) } else { '' }
        [void]$rows.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}<pre>{4}</pre></td><td>{5}<pre>{6}</pre></td></tr>' -f
            (& $encode $action.Change),(& $encode $action.ResourceKind),(& $encode $action.Key),$beforeHeading,(& $encode $beforeText),$afterHeading,(& $encode $afterText)))
    }
    $warnings = [System.Text.StringBuilder]::new()
    foreach ($warning in @($Plan.warnings)) { [void]$warnings.AppendLine(('<li>{0}</li>' -f (& $encode $warning))) }
    foreach ($difference in @($Plan.drift)) {
        [void]$warnings.AppendLine(('<li>DRIFT {0}/{1}: {2}</li>' -f (& $encode $difference.ResourceKind),(& $encode $difference.Key),(& $encode $difference.Change)))
    }
    $summary = 'Create {0} · Update {1} · Move {2} · Delete {3}' -f $Plan.summary.Create, $Plan.summary.Update, $Plan.summary.Move, $Plan.summary.Delete
    $status = if ($Plan.blocked) { 'BLOCKED — read-only preview; NOT safe to apply' } else { 'Ready for review (no apply implemented)' }
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>VCD Network Plan</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;max-width:1200px;color:#192536}table{width:100%;border-collapse:collapse}td,th{border:1px solid #cbd5e1;padding:10px;vertical-align:top;text-align:left}th{background:#eef3f7}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px} .blocked{color:#a31e1e;font-weight:bold} .notice{padding:12px;background:#fff7e5;border-left:4px solid #d98b00}</style></head>
<body><h1>Offline VCD Network Change Plan</h1>
<p>Environment: <strong>$(& $encode $Plan.environment)</strong> | Scope: <strong>$(& $encode $Plan.scope)</strong></p>
<p class="blocked">$(& $encode $status)</p><h2>$(& $encode $summary)</h2>
<section class="notice"><h3>Warnings and drift</h3><ul>$($warnings.ToString())</ul></section>
<table><thead><tr><th>Change</th><th>Kind</th><th>Logical key</th><th>Before (applied)</th><th>After (desired)</th></tr></thead><tbody>$($rows.ToString())</tbody></table>
<p>Generated locally. No live network requests or changes were made.</p></body></html>
"@
    [IO.File]::WriteAllText($htmlPath, $html, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Json = $jsonPath; Html = $htmlPath; Blocked = [bool]$Plan.blocked; Summary = $summary }
}
Export-ModuleMember -Function Get-OfflineNetworkPlan, Export-OfflineNetworkPlan

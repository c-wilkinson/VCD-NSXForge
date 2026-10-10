# Local synthetic starter templates. No live VMware requests or evaluation.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NetworkEditing.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NetworkEditorInputs.psm1') -ErrorAction Stop

function Get-NetworkRuleTemplates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[string]$AdditionalPath='')
    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.schemaVersion -ne 1 -or $data.synthetic -ne $true -or @($data.templates).Count -lt 1) { throw 'Unsupported rule template catalogue.' }
    $keys=@{}
    foreach ($template in @($data.templates)) {
        if ([string]$template.key -notmatch '^[a-z0-9-]{3,60}$' -or $keys.ContainsKey([string]$template.key)) { throw 'Invalid or duplicate rule template key.' }
        if ([string]::IsNullOrWhiteSpace([string]$template.name)) { throw 'Template name is required.' }
        if ([string]$template.action -cnotin @('ALLOW','DROP','REJECT')) { throw 'Invalid template action.' }
        foreach ($service in @($template.services)) {
            if ([string]$service.protocol -cnotin @('TCP','UDP','ICMP','ANY')) { throw 'Invalid template protocol.' }
        }
        $keys[[string]$template.key]=$true
    }
    $combined=@($data.templates)
    if ($AdditionalPath -and [IO.File]::Exists($AdditionalPath)) {
        $extras=Get-Content -LiteralPath $AdditionalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($extras.schemaVersion -ne 1 -or $extras.synthetic -ne $true) { throw 'Invalid local template catalogue.' }
        foreach ($t in @($extras.templates)) {
            if ([string]$t.key -notmatch '^[a-z0-9-]{3,60}$' -or $keys.ContainsKey([string]$t.key) -or [string]$t.action -cnotin @('ALLOW','DROP','REJECT')) { throw 'Invalid or duplicate local template.' }
            $keys[[string]$t.key]=$true;$combined+= $t
        }
    }
    return @($combined)
}

function New-NetworkRuleFromTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Documents,[Parameter(Mandatory)]$Template,
          [Parameter(Mandatory)][string]$Name)
    $candidateName=$Name.Trim()
    if (-not $candidateName) { throw 'Give the new rule a name.' }
    $keyBase=ConvertTo-NetworkEditorKey -Name $candidateName
    $key=$keyBase;$suffix=2
    while (@($Documents.edgeFirewallRules.items | Where-Object { $_.key -ceq $key }).Count -gt 0) {
        $key="$keyBase-$suffix"; $suffix++
        if ($suffix -gt 999) { throw 'Unable to generate a unique rule identifier.' }
    }
    $highest=-1
    foreach ($existing in @($Documents.edgeFirewallRules.items)) { $highest=[Math]::Max($highest,[int]$existing.order) }
    $services=@($Template.services | ForEach-Object { [pscustomobject]@{protocol=[string]$_.protocol;ports=[string[]]@($_.ports)} })
    $item=[pscustomobject]@{key=$key;name=$candidateName;description=[string]$Template.description;order=($highest+1);
        action=[string]$Template.action;enabled=$false;logging=[bool]$Template.logging;
        sourceIpSets=@();destinationIpSets=@();services=$services}
    # Deliberately disabled and any-source/destination until engineer reviews.
    $null=Set-NetworkDraftItem -Documents $Documents -ResourceKind edgeFirewallRules -Item $item -Create
    return $item
}

function Save-NetworkRuleTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)]$Rule,
          [Parameter(Mandatory)][string]$Name,
          [string]$BuiltInPath='')
    $key=ConvertTo-NetworkEditorKey -Name $Name
    if ($key.Length -lt 3) { throw 'Template name must contain at least three characters.' }
    if ($BuiltInPath) {
        foreach ($existing in @(Get-NetworkRuleTemplates -Path $BuiltInPath)) {
            if ($existing.key -ceq $key) { throw "A built-in template named '$key' already exists." }
        }
    }
    $template=[pscustomobject]@{key=$key;name=$Name.Trim();description=[string]$Rule.description;
        action=[string]$Rule.action;logging=[bool]$Rule.logging;
        services=@($Rule.services | ForEach-Object { [pscustomobject]@{protocol=[string]$_.protocol;ports=@($_.ports)} })}
    if ($template.action -cnotin @('ALLOW','DROP','REJECT')) { throw 'Unsupported template action.' }
    $data=if ([IO.File]::Exists($Path)) {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { [pscustomobject]@{schemaVersion=1;synthetic=$true;templates=@()} }
    if ($data.schemaVersion -ne 1 -or $data.synthetic -ne $true) { throw 'Invalid local template catalogue.' }
    if (@($data.templates | Where-Object { $_.key -ceq $key }).Count -gt 0) { throw "Template '$key' already exists." }
    $data.templates=@(@($data.templates) + @($template))
    if ($data.templates.Count -gt 100) { throw 'Too many local templates.' }
    $folder=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [void][IO.Directory]::CreateDirectory($folder)
    $json=ConvertTo-Json -InputObject $data -Depth 20
    $temp="$Path.$([guid]::NewGuid().ToString('n')).tmp"
    $backup="$Path.$([guid]::NewGuid().ToString('n')).bak"
    try {
        [IO.File]::WriteAllText($temp,$json,[System.Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,$backup) }
        else { [IO.File]::Move($temp,$Path) }
    }
    finally {
        foreach ($file in @($temp,$backup)) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
    }
    return $template
}

Export-ModuleMember -Function Get-NetworkRuleTemplates, New-NetworkRuleFromTemplate, Save-NetworkRuleTemplate

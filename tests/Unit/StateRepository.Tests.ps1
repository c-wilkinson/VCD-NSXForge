Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\State\StateRepository.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'src\Domain\State\StateModel.psm1') -Force

function New-RepositoryTestRoot {
    return (Join-Path ([IO.Path]::GetTempPath()) ('vcd-state-' + [guid]::NewGuid().ToString('n')))
}

Invoke-TestCase -Name 'Repository blocks environment and scope path traversal' -Body {
    $root = New-RepositoryTestRoot
    foreach ($segment in @('..','../evil','folder\child','C:drive','.hidden','a b','')) {
        Assert-Throws { Get-NetworkStateDirectory -StateRoot $root -Environment $segment -Scope 'edge' -View 'desired' }
        Assert-Throws { Get-NetworkStateDirectory -StateRoot $root -Environment 'prod' -Scope $segment -View 'desired' }
    }
}

Invoke-TestCase -Name 'Initialise desired state without inventing applied or observed data' -Body {
    $root = New-RepositoryTestRoot
    try {
        $path = Initialize-NetworkDesiredState -StateRoot $root -Environment 'test' -Scope 'edge01'
        Assert-True ([IO.Directory]::Exists($path))
        $desired = Read-NetworkStateView -StateRoot $root -Environment 'test' -Scope 'edge01' -View desired
        Assert-True $desired.Available
        Assert-Equal 3 $desired.Documents.Count
        Assert-True (-not (Read-NetworkStateView -StateRoot $root -Environment test -Scope edge01 -View applied).Available)
        Assert-True (-not (Read-NetworkStateView -StateRoot $root -Environment test -Scope edge01 -View observed).Available)
        Assert-Throws { Initialize-NetworkDesiredState -StateRoot $root -Environment test -Scope edge01 }
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Single-resource save uses atomic replacement and refuses blind overwrites' -Body {
    $root = New-RepositoryTestRoot
    try {
        $document = New-EmptyNetworkDocument -ResourceKind ipSets
        $saved = Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View desired -Document $document
        Assert-True ([IO.File]::Exists($saved.Path))
        Assert-Equal 64 $saved.Sha256.Length
        Assert-Throws { Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View desired -Document $document }
        # Replace with genuinely different data, so this tests the update path
        # and not just rewriting an identical JSON document.
        $updated = New-EmptyNetworkDocument -ResourceKind ipSets
        $updated.items = @([pscustomobject]@{ key='server'; name='Web Server'; addresses=@('10.20.0.10') })
        $replacement = Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View desired -Document $updated -ExpectedSha256 $saved.Sha256
        Assert-True ($replacement.Sha256 -ne $saved.Sha256) 'Replacing data should change the checksum'
        Assert-Equal 'server' (([IO.File]::ReadAllText($saved.Path) | ConvertFrom-Json).items[0].key)
        Assert-Throws { Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View desired -Document $document -ExpectedSha256 $saved.Sha256 }
        Assert-True ([IO.File]::Exists($saved.Path)) 'Failed conditional save must preserve current data'
        Assert-Equal 0 (@(Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in @('.lock','.tmp','.bak') }).Count)
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'State save does not overwrite existing data when validation fails' -Body {
    $root = New-RepositoryTestRoot
    try {
        $doc = New-EmptyNetworkDocument -ResourceKind ipSets
        $saved = Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View desired -Document $doc
        $bad = '{"schemaVersion":2,"resourceKind":"ipSets","items":[{"key":"oops","name":"Invalid","addresses":["nope"]}]}' | ConvertFrom-Json
        Assert-Throws { Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View desired -Document $bad -ExpectedSha256 $saved.Sha256 }
        Assert-Equal $saved.Sha256 (Get-NetworkFileSha256 -Path $saved.Path)
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Partial view fails closed rather than treating missing resources as empty' -Body {
    $root = New-RepositoryTestRoot
    try {
        $null = Save-NetworkStateDocument -StateRoot $root -Environment test -Scope edge01 -View observed -Document (New-EmptyNetworkDocument -ResourceKind ipSets)
        Assert-Throws { Read-NetworkStateView -StateRoot $root -Environment test -Scope edge01 -View observed }
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

Invoke-TestCase -Name 'Repository migrates legacy schema only in memory until explicit save' -Body {
    $root = New-RepositoryTestRoot
    try {
        $null = Initialize-NetworkDesiredState -StateRoot $root -Environment test -Scope edge01
        $path = Get-NetworkStateDocumentPath -StateRoot $root -Environment test -Scope edge01 -View desired -ResourceKind ipSets
        [IO.File]::WriteAllText($path,[IO.File]::ReadAllText((Join-Path $ProjectRoot 'tests\Fixtures\legacy-ip-sets-v1.json')))
        $view = Read-NetworkStateView -StateRoot $root -Environment test -Scope edge01 -View desired
        Assert-Equal 2 $view.Documents['ipSets'].schemaVersion
        Assert-Equal 1 ([IO.File]::ReadAllText($path) | ConvertFrom-Json).schemaVersion
    }
    finally { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) } }
}

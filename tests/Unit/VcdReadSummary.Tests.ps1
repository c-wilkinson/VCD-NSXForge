Import-Module (Join-Path $ProjectRoot 'src\Application\VcdRead\VcdReadSummary.psm1') -Force -ErrorAction Stop

Invoke-TestCase -Name 'Connection-only summary works without firewall resource counts or snapshot path' -Body {
    $result = [pscustomobject]@{Connected=$true;ApiVersion='39.0';SnapshotPath='';ObservedImported=$false}
    $summary = New-VcdReadCompletionSummary -Result $result -ConnectionOnly
    Assert-True ($summary.Message -match 'Connected successfully')
    Assert-True ($summary.Message -match '39.0')
    Assert-True ($summary.Message -match 'no snapshot created')
    Assert-True (-not $summary.Message.Contains('rules='))
}

Invoke-TestCase -Name 'Full snapshot summary includes actual counts and snapshot location' -Body {
    $result = [pscustomobject]@{Connected=$true;ApiVersion='39.0';SnapshotPath='reports\snapshot.json';FirewallRuleCount=4;IpSetCount=2;ReservationCount=3}
    $summary = New-VcdReadCompletionSummary -Result $result
    Assert-True ($summary.Message -match 'firewall rules=4')
    Assert-True ($summary.Message -match 'IP Sets=2')
    Assert-True ($summary.Message -match 'reservations=3')
    Assert-True ($summary.Message.Contains('reports\snapshot.json'))
}

Invoke-TestCase -Name 'Missing required snapshot counts fail clearly but never affect connection-only check' -Body {
    $partial = [pscustomobject]@{Connected=$true;ApiVersion='39.0';SnapshotPath=''}
    Assert-Throws { New-VcdReadCompletionSummary -Result $partial } 'Snapshot with incomplete counts must be rejected'
    Assert-True ((New-VcdReadCompletionSummary -Result $partial -ConnectionOnly).Message -match 'Connected successfully')
    Assert-Throws { New-VcdReadCompletionSummary -Result ([pscustomobject]@{Connected=$false;ApiVersion='39.0'}) -ConnectionOnly } 'Unsuccessful connection cannot be reported as successful'
}

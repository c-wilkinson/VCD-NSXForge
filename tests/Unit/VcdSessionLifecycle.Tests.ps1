Import-Module (Join-Path $ProjectRoot 'src\Domain\Access\VcdSessionLifecycle.psm1') -ErrorAction Stop

Invoke-TestCase -Name 'Session lifecycle distinguishes unknown expiry, expiring and expired with clock skew' -Body {
    $now = [datetime]::SpecifyKind([datetime]'2026-10-11T12:00:00', [DateTimeKind]::Utc)
    $unknown = Get-VcdSessionLifecycleState -Status Valid -NowUtc $now
    Assert-Equal 'Valid' $unknown.Status
    Assert-True (-not $unknown.ExpiryKnown)
    $future = Get-VcdSessionLifecycleState -Status Valid -ExpiresUtc $now.AddMinutes(5) -NowUtc $now
    Assert-Equal 'Valid' $future.Status
    $soon = Get-VcdSessionLifecycleState -Status Valid -ExpiresUtc $now.AddSeconds(40) -NowUtc $now
    Assert-Equal 'Expiring' $soon.Status
    Assert-True (-not $soon.CanUseToken) 'Do not start a long read with a nearly expired token'
    $past = Get-VcdSessionLifecycleState -Status Valid -ExpiresUtc $now.AddSeconds(-1) -NowUtc $now
    Assert-Equal 'Expired' $past.Status
    Assert-True (-not $past.CanUseToken)
}

Invoke-TestCase -Name 'Session lifecycle refuses to promote a revoked or failed renewal token' -Body {
    foreach ($state in @('Revoked/Forbidden','RenewalUnavailable','ReauthenticationRequired')) {
        $health = Get-VcdSessionLifecycleState -Status $state -ExpiresUtc ([datetime]::UtcNow.AddHours(2))
        Assert-Equal $state $health.Status
        Assert-True (-not $health.CanUseToken)
        Assert-True $health.RequiresOperator
    }
}

Invoke-TestCase -Name 'Expiry metadata requires an explicit trusted timezone and never guesses JWT lifetime' -Body {
    Assert-True ($null -eq (Get-VcdVerifiedSessionExpiry -Session ([pscustomobject]@{id='example'})))
    $date = Get-VcdVerifiedSessionExpiry -Session ([pscustomobject]@{ expirationDate='2026-10-11T14:00:00+02:00' })
    Assert-Equal 12 $date.Hour
    $dateParsed = Get-VcdVerifiedSessionExpiry -Session ([pscustomobject]@{ expirationDate=[datetime]::SpecifyKind([datetime]'2026-10-11T12:00:00', [DateTimeKind]::Utc) })
    Assert-Equal 12 $dateParsed.Hour
    Assert-Throws { Get-VcdVerifiedSessionExpiry -Session ([pscustomobject]@{ expirationDate='2026-10-11T14:00:00' }) }
    Assert-Throws { Get-VcdVerifiedSessionExpiry -Session ([pscustomobject]@{ expirationDate='2026-10-11T14:00:00Znotvalid' }) }
}

Invoke-TestCase -Name 'Renewed identity may rotate session ID but cannot change user, tenant or provider rights' -Body {
    $old = [pscustomobject]@{ User='engineer'; SessionId='old'; SessionOrgId='orgA'; TargetOrgId='orgA'; LoginScope='Tenant'; IsProvider=$false }
    $same = [pscustomobject]@{ User='engineer'; SessionId='new'; SessionOrgId='orgA'; TargetOrgId='orgA'; LoginScope='Tenant'; IsProvider=$false }
    Confirm-VcdRenewedSessionIdentity -Original $old -Renewed $same
    foreach ($changed in @('User','SessionOrgId','TargetOrgId','LoginScope','IsProvider')) {
        $other = $same.PSObject.Copy()
        if ($changed -eq 'IsProvider') { $other.IsProvider = $true }
        else { $other.$changed = 'other' }
        Assert-Throws { Confirm-VcdRenewedSessionIdentity -Original $old -Renewed $other }
    }
}

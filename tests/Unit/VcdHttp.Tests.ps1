Import-Module (Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1') -Force

Invoke-TestCase -Name 'VCD HTTP adapter rejects HTTP and URL path injection without any network connection' -Body {
    foreach ($url in @('http://vcd.example.test','https://vcd.example.test/cloudapi','https://user:pass@vcd.example.test')) {
        Assert-Throws { New-VcdHttpTransport -BaseUri ([uri]$url) }
    }
}

Invoke-TestCase -Name 'VCD HTTP adapter refuses mutating network methods without network' -Body {
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test')
    try {
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{ Method='PUT'; Uri='https://vcd.example.test/cloudapi/1.0.0/firewallGroups'; Headers=@{} }) }
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{ Method='DELETE'; Uri='https://vcd.example.test/cloudapi/1.0.0/firewallGroups'; Headers=@{} }) }
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{ Method='GET'; Uri='https://other.example.test/api/versions'; Headers=@{} }) }
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

# Inspect PowerShell code with its parser rather than a line-based regex.
# An indented comment must not be mistaken for a certificate-bypass setting.
function Get-VcdHttpExecutableText {
    param([Parameter(Mandatory)][string]$Source)

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Unable to inspect VCD HTTP source: $($parseErrors[0].Message)"
    }

    $ignoredKinds = @(
        [System.Management.Automation.Language.TokenKind]::Comment
        [System.Management.Automation.Language.TokenKind]::StringLiteral
        [System.Management.Automation.Language.TokenKind]::StringExpandable
        [System.Management.Automation.Language.TokenKind]::HereStringLiteral
        [System.Management.Automation.Language.TokenKind]::HereStringExpandable
    )
    return (@($tokens | Where-Object { $ignoredKinds -notcontains $_.Kind } |
        ForEach-Object { $_.Text }) -join ' ')
}

Invoke-TestCase -Name 'HTTP implementation disallows redirects cookies and certificate bypass' -Body {
    $source = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\Infrastructure\VcdApi\VcdHttp.psm1'))
    Assert-True ($source.Contains('AllowAutoRedirect = $false'))
    Assert-True ($source.Contains('UseCookies = $false'))
    $executableText = Get-VcdHttpExecutableText -Source $source
    foreach ($unsafe in @('ServerCertificateValidationCallback', 'DangerousAcceptAnyServerCertificateValidator', 'SkipCertificateCheck')) {
        Assert-True (-not ($executableText -match [regex]::Escape($unsafe))) "Unsafe certificate setting: $unsafe"
    }
}

Invoke-TestCase -Name 'HTTP safety scan ignores comments but detects executable certificate bypass' -Body {
    $commentOnly = '    # Do not use -SkipCertificateCheck or ServerCertificateValidationCallback'
    Assert-True (-not ((Get-VcdHttpExecutableText -Source $commentOnly) -match 'SkipCertificateCheck'))

    $unsafeCode = 'Invoke-WebRequest -Uri https://vcd.example.test -SkipCertificateCheck'
    Assert-True ((Get-VcdHttpExecutableText -Source $unsafeCode) -match 'SkipCertificateCheck')
}

. (Join-Path $ProjectRoot 'tests\Mocks\FakeHttpHandler.ps1')

Invoke-TestCase -Name 'Real HTTP adapter uses fake in-memory handler to login and read with bearer token' -Body {
    $fake = [VcdMockHttpHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test:8443') -Handler $fake
    try {
        $secret = ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force
        $credential = [pscredential]::new('user@org', $secret)
        Connect-VcdHttpTransport -Transport $transport -Credential $credential -ApiVersion '39.0'
        Assert-Equal 'POST' $fake.LastMethod
        Assert-Equal '/cloudapi/1.0.0/sessions' $fake.LastPath
        Assert-Equal 'Basic' $fake.LastAuthScheme
        $result = & $transport.RequestSender ([pscustomobject]@{
            Method='GET'; Uri='https://vcd.example.test:8443/cloudapi/1.0.0/sessions/current'; Headers=@{Accept='application/json;version=39.0'}
        })
        Assert-Equal 'Bearer' $fake.LastAuthScheme
        Assert-Equal 'synthetic-token-123' $fake.LastAuthParameter
        Assert-Equal 'urn:vcloud:session:example' $result.id
        Assert-Equal 2 $fake.Count
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name 'Real HTTP adapter supports provider login with mock handler and bearer-token mode' -Body {
    $fake = [VcdMockHttpHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test') -Handler $fake
    try {
        $secret = ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force
        Connect-VcdHttpTransport -Transport $transport -Credential ([pscredential]::new('administrator@system', $secret)) -ProviderLogin
        Assert-Equal '/cloudapi/1.0.0/sessions/provider' $fake.LastPath
        Connect-VcdHttpTransport -Transport $transport -BearerToken 'synthetic-another-token'
        $null = & $transport.RequestSender ([pscustomobject]@{ Method='GET'; Uri='https://vcd.example.test/cloudapi/1.0.0/sessions/current'; Headers=@{} })
        Assert-Equal 'synthetic-another-token' $fake.LastAuthParameter
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

Invoke-TestCase -Name 'Real HTTP adapter rejects redirects and HTTP failures without exposing body or token' -Body {
    $fake = [VcdMockHttpHandler]::new()
    $transport = New-VcdHttpTransport -BaseUri ([uri]'https://vcd.example.test') -Handler $fake
    try {
        $fake.Mode = 'Redirect'
        Assert-Throws { & $transport.RequestSender ([pscustomobject]@{ Method='GET'; Uri='https://vcd.example.test/api/versions'; Headers=@{} }) }
        $fake.Mode = 'Error'
        $captured = ''
        try { $null = & $transport.RequestSender ([pscustomobject]@{ Method='GET'; Uri='https://vcd.example.test/api/versions'; Headers=@{} }) }
        catch { $captured = $_.Exception.Message }
        Assert-True ($captured -match '503')
        Assert-True (-not $captured.Contains('sensitive server data'))
    }
    finally { Close-VcdHttpTransport -Transport $transport }
}

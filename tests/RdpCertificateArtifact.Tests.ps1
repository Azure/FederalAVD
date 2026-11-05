$repoRoot = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $repoRoot 'customer-examples\artifacts\Configure-RdpCertificate'
. (Join-Path $artifact 'scripts\Common.ps1')
. (Join-Path $artifact 'scripts\Bootstrap.ps1')

function Test-Rejected {
    param([scriptblock]$Action, [string]$MessagePattern = '.')
    # Pester 3's Should Throw does not reliably execute scriptblocks on PowerShell 7.
    try { & $Action | Out-Null; return $false }
    catch { return $_.Exception.Message -match $MessagePattern }
}

Describe 'RDP certificate artifact packaging' {
    It 'has one entry point and documents qualification and bootstrap' {
        @(Get-ChildItem -LiteralPath $artifact -Filter '*.ps1' -File).Count | Should Be 1
        $readme = Get-Content -LiteralPath (Join-Path $artifact 'README.md') -Raw
        $readme | Should Match 'Qualification status'
        $readme | Should Match 'One-time trusted bootstrap'
        $readme | Should Match 'RequestDisposition & 0x100'
    }

    It 'contains only ASCII PowerShell that parses' {
        foreach ($file in Get-ChildItem -LiteralPath $artifact -Filter '*.ps1' -Recurse) {
            @(Get-Content -LiteralPath $file.FullName | Where-Object { $_ -match '[^\x00-\x7E]' }).Count | Should Be 0
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should Be 0
        }
    }

    It 'does not use password enrollment or trust and policy bypasses' {
        $content = (Get-ChildItem -LiteralPath $artifact -Filter '*.ps1' -Recurse |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $content | Should Not Match 'Get-AzKeyVaultSecret|UseDefaultCredentials|SkipCertificateCheck'
        $content | Should Not Match 'ExecutionPolicy\s+Bypass|SkipSignatureValidation|RevocationMode\]::NoCheck'
    }
}

Describe 'RDP certificate request policy' {
    BeforeEach {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        $dns = 'avd001.example.internal'
    }
    AfterEach { $rsa.Dispose() }

    It 'accepts the exact RDP profile with a valid signature' {
        $request = New-ProfileRequest $dns $rsa rdp
        $loaded = Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp
        (Get-PublicKeyHash $loaded.PublicKey) | Should Be (Get-PublicKeyHash $request.PublicKey)
    }

    It 'accepts the separate client-authentication profile' {
        $request = New-ProfileRequest $dns $rsa credential
        $loaded = Read-ValidatedRequest $request.CreateSigningRequestPem() $dns credential
        $loaded.CertificateExtensions.Count | Should Be 4
    }

    It 'rejects a request for another host' {
        $pem = (New-ProfileRequest $dns $rsa rdp).CreateSigningRequestPem()
        (Test-Rejected { Read-ValidatedRequest $pem 'avd002.example.internal' rdp } 'authorized host CN') | Should Be $true
    }

    It 'rejects a client-authentication request on the RDP route' {
        $pem = (New-ProfileRequest $dns $rsa credential).CreateSigningRequestPem()
        (Test-Rejected { Read-ValidatedRequest $pem $dns rdp } 'authorized profile') | Should Be $true
    }

    It 'rejects an RDP request on the credential route' {
        $pem = (New-ProfileRequest $dns $rsa rdp).CreateSigningRequestPem()
        (Test-Rejected { Read-ValidatedRequest $pem $dns credential } 'authorized profile') | Should Be $true
    }

    It 'rejects weak RSA keys' {
        $weak = [Security.Cryptography.RSA]::Create(2048)
        try {
            $pem = (New-ProfileRequest $dns $weak rdp).CreateSigningRequestPem()
            (Test-Rejected { Read-ValidatedRequest $pem $dns rdp } '3072') | Should Be $true
        }
        finally { $weak.Dispose() }
    }

    It 'rejects additional names' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.CertificateExtensions.RemoveAt(3)
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName($dns)
        $san.AddDnsName('another.example.internal')
        $request.CertificateExtensions.Add($san.Build())
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'authorized profile') | Should Be $true
    }

    It 'rejects CA capability' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.CertificateExtensions.RemoveAt(0)
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true)
        )
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'authorized profile') | Should Be $true
    }

    It 'rejects a missing required extension' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.CertificateExtensions.RemoveAt(3)
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'missing') | Should Be $true
    }

    It 'rejects duplicate extensions' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.CertificateExtensions.Add($request.CertificateExtensions[3])
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp }) | Should Be $true
    }

    It 'rejects extra extensions' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false)
        )
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'Unapproved extension') | Should Be $true
    }

    It 'rejects changed criticality' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.CertificateExtensions[3].Critical = $true
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'authorized profile') | Should Be $true
    }

    It 'rejects extra signed request attributes' {
        $request = New-ProfileRequest $dns $rsa rdp
        $request.OtherRequestAttributes.Add([Security.Cryptography.AsnEncodedData]::new(
            [Security.Cryptography.Oid]::new('1.2.840.113549.1.9.7'), [byte[]](12, 1, 120)
        ))
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'attributes') | Should Be $true
    }

    It 'rejects SHA-384 signed requests rather than confusing the loader hash with the actual signature' {
        $profile = New-ProfileRequest $dns $rsa rdp
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$dns", $rsa, [Security.Cryptography.HashAlgorithmName]::SHA384,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        foreach ($extension in $profile.CertificateExtensions) { $request.CertificateExtensions.Add($extension) }
        (Test-Rejected { Read-ValidatedRequest $request.CreateSigningRequestPem() $dns rdp } 'SHA-256') | Should Be $true
    }

    It 'rejects tampered signatures' {
        $pem = (New-ProfileRequest $dns $rsa rdp).CreateSigningRequestPem()
        $der = [Convert]::FromBase64String(($pem -replace '-----BEGIN CERTIFICATE REQUEST-----|-----END CERTIFICATE REQUEST-----|\s', ''))
        $der[$der.Length - 1] = $der[$der.Length - 1] -bxor 1
        $tampered = "-----BEGIN CERTIFICATE REQUEST-----`n$([Convert]::ToBase64String($der))`n-----END CERTIFICATE REQUEST-----"
        (Test-Rejected { Read-ValidatedRequest $tampered $dns rdp }) | Should Be $true
    }

    It 'rejects concatenated requests and oversized input' {
        $pem = (New-ProfileRequest $dns $rsa rdp).CreateSigningRequestPem()
        (Test-Rejected { Read-ValidatedRequest "$pem`n$pem" $dns rdp } 'one PEM') | Should Be $true
        (Test-Rejected { Read-ValidatedRequest ('x' * 16385) $dns rdp } 'one PEM') | Should Be $true
    }

    It 'rejects trailing DER objects inside a single PEM envelope' {
        $pem = (New-ProfileRequest $dns $rsa rdp).CreateSigningRequestPem()
        $der = [Convert]::FromBase64String(($pem -replace '-----BEGIN CERTIFICATE REQUEST-----|-----END CERTIFICATE REQUEST-----|\s', ''))
        $extended = [byte[]]($der + [byte[]](5, 0))
        $trailing = "-----BEGIN CERTIFICATE REQUEST-----`n$([Convert]::ToBase64String($extended))`n-----END CERTIFICATE REQUEST-----"
        (Test-Rejected { Read-ValidatedRequest $trailing $dns rdp }) | Should Be $true
    }

    It 'rejects wildcards, uppercase names, IPs and invalid labels' {
        foreach ($name in @('*.example.internal', 'AVD001.example.internal', '10.0.0.1', '-bad.example.internal', 'host')) {
            (Test-Rejected { Assert-DnsName $name } 'FQDN') | Should Be $true
        }
    }
}

Describe 'Issued RDP certificate property validation' {
    BeforeEach {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        $dns = 'avd001.example.internal'
        $request = New-ProfileRequest $dns $rsa rdp
        $policy = [pscustomobject]@{ MaximumValidityDays = 397; RenewBeforeDays = 30 }
        $keyHash = Get-PublicKeyHash $request.PublicKey
    }
    AfterEach { $rsa.Dispose() }

    It 'accepts the exact issued leaf profile without treating it as a CA' {
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(90))
        try {
            Assert-Profile $certificate.SubjectName $certificate.Extensions $certificate.PublicKey $dns rdp -Issued
        }
        finally { $certificate.Dispose() }
    }

    It 'rejects a response with a different public key before attempting chain retrieval' {
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(90))
        try {
            (Test-Rejected { Assert-Certificate $certificate $dns rdp $policy ('0' * 64) } 'expected public key') | Should Be $true
        }
        finally { $certificate.Dispose() }
    }

    It 'rejects an excessive lifetime measured from NotBefore, including backdating' {
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(397))
        try {
            (Test-Rejected { Assert-Certificate $certificate $dns rdp $policy $keyHash } 'validity') | Should Be $true
        }
        finally { $certificate.Dispose() }
    }

    It 'rejects a newly issued certificate that is already inside the renewal window' {
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(29))
        try {
            (Test-Rejected { Assert-Certificate $certificate $dns rdp $policy $keyHash -NewlyIssued } 'outlast the renewal window') | Should Be $true
        }
        finally { $certificate.Dispose() }
    }

    It 'rejects an expired certificate before attempting chain retrieval' {
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-10), [DateTimeOffset]::UtcNow.AddDays(-1))
        try {
            (Test-Rejected { Assert-Certificate $certificate $dns rdp $policy $keyHash } 'validity') | Should Be $true
        }
        finally { $certificate.Dispose() }
    }
}

$serverAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $artifact 'scripts\Server.ps1'), [ref]$null, [ref]$null
)
$policyFunctions = $serverAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Assert-CaConfiguration', 'Get-AuthorizedHost', 'Get-IssuedCertificate')
}, $true)
# Load only the actual policy functions; do not start HTTP.sys or require a local CA in unit tests.
. ([scriptblock]::Create("using namespace System.Security.Cryptography.X509Certificates`n" +
    (($policyFunctions | ForEach-Object { $_.Extent.Text }) -join "`n")))

Describe 'Gateway authorization and request replay' {
    BeforeEach {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        $dns = 'avd001.example.internal'
        $credentialRequest = New-ProfileRequest $dns $rsa credential
        $credential = $credentialRequest.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(90)
        )
        $config = [pscustomobject]@{
            RenewBeforeDays = 30
            Hosts = @([pscustomobject]@{
                DnsName = $dns
                EnrollmentPublicKeySha256 = Get-PublicKeyHash $credential.PublicKey
            })
        }
        $data = $TestDrive
        Mock Assert-CaConfiguration {}
        Mock Assert-Certificate {}
    }
    AfterEach { $credential.Dispose(); $rsa.Dispose() }

    It 'maps an authenticated enrollment public key to the administrator-controlled host name' {
        (Get-AuthorizedHost $credential).DnsName | Should Be $dns
        Assert-MockCalled Assert-Certificate -Times 1 -Exactly -Scope It
    }

    It 'rejects a key absent from the administrator allowlist' {
        $config.Hosts[0].EnrollmentPublicKeySha256 = '0' * 64
        (Test-Rejected { Get-AuthorizedHost $credential } 'not authorized') | Should Be $true
        Assert-MockCalled Assert-Certificate -Times 0 -Exactly -Scope It
    }

    It 'does not allow credential renewal to substitute a new enrollment key' {
        $pem = $credentialRequest.CreateSigningRequestPem()
        (Test-Rejected { Get-IssuedCertificate $pem $dns credential ('0' * 64) } 'cannot change') | Should Be $true
    }

    It 'replays the recorded response for an identical request outside the renewal window' {
        $request = New-ProfileRequest $dns $rsa rdp
        $pem = $request.CreateSigningRequestPem()
        $certificate = $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(90)
        )
        try {
            $hash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($pem))
            $path = Join-Path $data ((Get-BytesHash ([Text.Encoding]::UTF8.GetBytes("$dns|rdp"))) + '.json')
            $encoded = [Convert]::ToBase64String($certificate.RawData)
            Write-JsonFile $path @{ RequestSha256 = $hash; RequestId = 42; Certificate = $encoded }
            $result = Get-IssuedCertificate $pem $dns rdp (Get-PublicKeyHash $credential.PublicKey)
            $result.RequestSha256 | Should Be $hash
            $result.Certificate | Should Be $encoded
            (Get-IssuedCertificate $pem $dns RDP (Get-PublicKeyHash $credential.PublicKey)).Certificate | Should Be $encoded
        }
        finally { $certificate.Dispose() }
    }

    It 'rejects a different request outside the renewal window before calling AD CS' {
        $request = New-ProfileRequest $dns $rsa rdp
        $pem = $request.CreateSigningRequestPem()
        $certificate = $request.CreateSelfSigned(
            [DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(90)
        )
        try {
            $path = Join-Path $data ((Get-BytesHash ([Text.Encoding]::UTF8.GetBytes("$dns|rdp"))) + '.json')
            Write-JsonFile $path @{
                RequestSha256 = '0' * 64; RequestId = 42
                Certificate = [Convert]::ToBase64String($certificate.RawData)
            }
            (Test-Rejected { Get-IssuedCertificate $pem $dns rdp (Get-PublicKeyHash $credential.PublicKey) } 'outside the renewal window') | Should Be $true
        }
        finally { $certificate.Dispose() }
    }

    It 'does not replace another pending request with a new CSR' {
        $pem = (New-ProfileRequest $dns $rsa rdp).CreateSigningRequestPem()
        $path = Join-Path $data ((Get-BytesHash ([Text.Encoding]::UTF8.GetBytes("$dns|rdp"))) + '.json')
        Write-JsonFile $path @{ RequestSha256 = '0' * 64; RequestId = 42; Certificate = $null }
        (Test-Rejected { Get-IssuedCertificate $pem $dns rdp (Get-PublicKeyHash $credential.PublicKey) } 'already pending') | Should Be $true
    }
}

Describe 'RDP certificate automation boundaries' {
    It 'pins the CA and checks revocation rather than accepting a matching name alone' {
        $content = Get-Content -LiteralPath (Join-Path $artifact 'scripts\Common.ps1') -Raw
        $content | Should Match 'X509RevocationMode\]::Online'
        $content | Should Match 'ChainElements\[1\]'
        $content | Should Match 'RootCaSha256'
    }

    It 'checks actual listener presentation before cleanup or bootstrap removal' {
        $content = Get-Content -LiteralPath (Join-Path $artifact 'scripts\Host.ps1') -Raw
        $probe = $content.LastIndexOf('Assert-ListenerCertificate $config.')
        $cleanup = $content.IndexOf('Remove-Item -LiteralPath $oldPath')
        $unregister = $content.IndexOf('Unregister-ScheduledTask')
        ($probe -gt 0 -and $cleanup -gt $probe -and $unregister -gt $cleanup) | Should Be $true
        $content | Should Not Match 'Restart-Service|Stop-Service'
    }

    It 'records request IDs before approval and uses the pending-first policy' {
        $content = Get-Content -LiteralPath (Join-Path $artifact 'scripts\Server.ps1') -Raw
        ($content.IndexOf('Write-JsonFile $path $state') -lt $content.IndexOf('$admin.ResubmitRequest')) | Should Be $true
        $content | Should Match 'RequestDisposition -band 0x100'
        $content | Should Match 'OtherRequestAttributes|Read-ValidatedRequest'
    }

    It 'uses mutual TLS and a pinned enrollment public key, not client-supplied names' {
        $content = Get-Content -LiteralPath (Join-Path $artifact 'scripts\Server.ps1') -Raw
        $content | Should Match 'GetClientCertificate'
        $content | Should Match 'EnrollmentPublicKeySha256 -ceq \$keyHash'
        $content | Should Match 'Get-IssuedCertificate \$payload.Csr \$hostEntry.DnsName'
        $content | Should Match 'Enrollment renewal cannot change'
    }
}

#requires -Version 7.4
using namespace System.Security.Cryptography
using namespace System.Security.Cryptography.X509Certificates

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BytesHash {
    param([byte[]]$Bytes)
    [Convert]::ToHexString([SHA256]::HashData($Bytes))
}

function Get-PublicKeyHash {
    param([PublicKey]$PublicKey)
    Get-BytesHash $PublicKey.ExportSubjectPublicKeyInfo()
}

function Get-OptionalValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Test-AutomaticBootstrap {
    param($Configuration)
    (Get-OptionalValue (Get-OptionalValue $Configuration Bootstrap) Enabled) -eq $true
}

function Get-ProvisioningScriptHash {
    param([string]$Script)
    Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($Script.TrimStart([char]0xFEFF).Replace("`r`n", "`n")))
}

function Get-AzureVmIdentity {
    $metadata = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' `
        -Headers @{ Metadata = 'true' } -NoProxy -TimeoutSec 15
    $vmId = ([Guid]::Parse($metadata.vmId)).ToString('D')
    if ($vmId -eq [Guid]::Empty.ToString()) { throw 'IMDS did not return a VM incarnation ID.' }
    [pscustomobject]@{
        VmId = $vmId
        VmResourceId = "/subscriptions/$($metadata.subscriptionId)/resourceGroups/$($metadata.resourceGroupName)/providers/Microsoft.Compute/virtualMachines/$($metadata.name)"
    }
}

function Assert-DnsName {
    param([string]$Name)
    $address = $null
    if ([Net.IPAddress]::TryParse($Name, [ref]$address) -or $Name.Length -gt 253 -or
        $Name -cnotmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw [ArgumentException]::new('Use a lowercase, explicit host FQDN, without wildcards.')
    }
}

function New-ProfileRequest {
    param(
        [string]$DnsName,
        [RSA]$Key,
        [ValidateSet('rdp', 'credential')][string]$Profile
    )
    Assert-DnsName $DnsName
    $request = [CertificateRequest]::new(
        "CN=$DnsName", $Key, [HashAlgorithmName]::SHA256, [RSASignaturePadding]::Pkcs1
    )
    $request.CertificateExtensions.Add([X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $usage = [X509KeyUsageFlags]::DigitalSignature
    $eku = '1.3.6.1.5.5.7.3.2'
    if ($Profile -eq 'rdp') {
        $usage = $usage -bor [X509KeyUsageFlags]::KeyEncipherment
        $eku = '1.3.6.1.5.5.7.3.1'
    }
    $request.CertificateExtensions.Add([X509KeyUsageExtension]::new($usage, $true))
    $oids = [OidCollection]::new()
    [void]$oids.Add([Oid]::new($eku))
    $request.CertificateExtensions.Add([X509EnhancedKeyUsageExtension]::new($oids, $false))
    $san = [SubjectAlternativeNameBuilder]::new()
    $san.AddDnsName($DnsName)
    $request.CertificateExtensions.Add($san.Build())
    return $request
}

function Assert-Profile {
    param(
        [X500DistinguishedName]$Subject,
        $Extensions,
        [PublicKey]$PublicKey,
        [string]$DnsName,
        [ValidateSet('rdp', 'credential')][string]$Profile,
        [switch]$Issued
    )
    $expectedSubject = [X500DistinguishedName]::new("CN=$DnsName")
    if ([Convert]::ToBase64String($Subject.RawData) -cne [Convert]::ToBase64String($expectedSubject.RawData)) {
        throw [Security.SecurityException]::new('The subject is not the authorized host CN.')
    }
    if ($PublicKey.Oid.Value -ne '1.2.840.113549.1.1.1') {
        throw [Security.SecurityException]::new('Only RSA keys are accepted.')
    }
    $rsa = $PublicKey.GetRSAPublicKey()
    try {
        if ($rsa.KeySize -lt 3072) {
            throw [Security.SecurityException]::new('RSA keys must be at least 3072 bits.')
        }
        $expected = New-ProfileRequest $DnsName $rsa $Profile
    }
    finally { $rsa.Dispose() }
    $seen = @{}
    $metadataOids = @('2.5.29.14', '2.5.29.35', '2.5.29.31', '1.3.6.1.5.5.7.1.1')
    foreach ($extension in $Extensions) {
        $oid = $extension.Oid.Value
        if ($seen.ContainsKey($oid)) {
            throw [Security.SecurityException]::new("Duplicate extension: $oid")
        }
        $seen[$oid] = $extension
        $match = @($expected.CertificateExtensions | Where-Object { $_.Oid.Value -eq $oid })
        if ($match.Count -eq 0) {
            if (-not $Issued -or $oid -notin $metadataOids -or $extension.Critical) {
                throw [Security.SecurityException]::new("Unapproved extension: $oid")
            }
        }
        elseif ($extension.Critical -ne $match[0].Critical -or
            [Convert]::ToBase64String($extension.RawData) -cne [Convert]::ToBase64String($match[0].RawData)) {
            throw [Security.SecurityException]::new("Extension does not match the authorized profile: $oid")
        }
    }
    foreach ($extension in $expected.CertificateExtensions) {
        if (-not $seen.ContainsKey($extension.Oid.Value)) {
            throw [Security.SecurityException]::new("Required extension is missing: $($extension.Oid.Value)")
        }
    }
}

function Read-ValidatedRequest {
    param(
        [string]$Pem,
        [string]$DnsName,
        [ValidateSet('rdp', 'credential')][string]$Profile
    )
    if ($Pem.Length -gt 16384 -or $Pem -cnotmatch '\A-----BEGIN CERTIFICATE REQUEST-----\s+([A-Za-z0-9+/=\r\n]+)\s+-----END CERTIFICATE REQUEST-----\s*\z') {
        throw [ArgumentException]::new('Expected one PEM PKCS#10 request of at most 16 KiB.')
    }
    $der = [Convert]::FromBase64String($Matches[1])
    $reader = [System.Formats.Asn1.AsnReader]::new(
        [ReadOnlyMemory[byte]]::new($der), [System.Formats.Asn1.AsnEncodingRules]::DER
    )
    $sequence = $reader.ReadSequence()
    [void]$sequence.ReadEncodedValue()
    $algorithm = $sequence.ReadSequence()
    if ($algorithm.ReadObjectIdentifier() -ne '1.2.840.113549.1.1.11') {
        throw [Security.SecurityException]::new('The CSR must be signed with RSA PKCS#1 SHA-256.')
    }
    $algorithm.ReadNull()
    $algorithm.ThrowIfNotEmpty()
    $unusedBits = 0
    [void]$sequence.ReadBitString([ref]$unusedBits)
    if ($unusedBits -ne 0) { throw [ArgumentException]::new('Invalid RSA signature encoding.') }
    $sequence.ThrowIfNotEmpty()
    $reader.ThrowIfNotEmpty()
    # Loading verifies the signature. Only extension loading is enabled; signature bypass is not.
    $request = [CertificateRequest]::LoadSigningRequestPem(
        $Pem, [HashAlgorithmName]::SHA256,
        [CertificateRequestLoadOptions]::UnsafeLoadCertificateExtensions,
        [RSASignaturePadding]::Pkcs1
    )
    if ($request.OtherRequestAttributes.Count -ne 0) {
        throw [Security.SecurityException]::new('Additional CSR attributes are not permitted.')
    }
    Assert-Profile $request.SubjectName $request.CertificateExtensions $request.PublicKey $DnsName $Profile
    return $request
}

function Assert-Certificate {
    param(
        [X509Certificate2]$Certificate,
        [string]$DnsName,
        [ValidateSet('rdp', 'credential')][string]$Profile,
        $Configuration,
        [string]$PublicKeyHash,
        [switch]$NewlyIssued
    )
    Assert-Profile $Certificate.SubjectName $Certificate.Extensions $Certificate.PublicKey $DnsName $Profile -Issued
    if ((Get-PublicKeyHash $Certificate.PublicKey) -cne $PublicKeyHash) {
        throw [Security.SecurityException]::new('The certificate does not contain the expected public key.')
    }
    if ($Certificate.SignatureAlgorithm.Value -notin @(
        '1.2.840.113549.1.1.11', '1.2.840.113549.1.1.12', '1.2.840.113549.1.1.13'
    ) -or $Certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
        $Certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or
        ($Certificate.NotAfter - $Certificate.NotBefore).TotalDays -gt $Configuration.MaximumValidityDays) {
        throw [Security.SecurityException]::new('The certificate signature or validity is outside policy.')
    }
    if ($NewlyIssued -and $Certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddDays($Configuration.RenewBeforeDays)) {
        throw [Security.SecurityException]::new('A newly issued certificate must outlast the renewal window.')
    }
    $chain = [X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(15)
        $eku = if ($Profile -eq 'rdp') { '1.3.6.1.5.5.7.3.1' } else { '1.3.6.1.5.5.7.3.2' }
        [void]$chain.ChainPolicy.ApplicationPolicy.Add([Oid]::new($eku))
        if (-not $chain.Build($Certificate)) {
            throw [Security.SecurityException]::new("Certificate chain/revocation failed: $($chain.ChainStatus.Status -join ',')")
        }
        if ($chain.ChainElements.Count -lt 2 -or
            (Get-BytesHash $chain.ChainElements[1].Certificate.RawData) -cne $Configuration.IssuingCaSha256 -or
            (Get-BytesHash $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.RawData) -cne $Configuration.RootCaSha256) {
            throw [Security.SecurityException]::new('The issuing CA or root CA does not match the configured SHA-256 pin.')
        }
    }
    finally { $chain.Dispose() }
}

function Read-JsonFile {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $temporary = "$Path.new"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path, $true)
}

function Write-Audit {
    param([string]$Directory, [string]$Event, [string]$Detail)
    $path = Join-Path $Directory 'audit.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 5MB) {
        Move-Item -LiteralPath $path -Destination "$path.1" -Force
    }
    $line = @{ Time = [DateTime]::UtcNow.ToString('o'); Event = $Event; Detail = $Detail } | ConvertTo-Json -Compress
    Add-Content -LiteralPath $path -Value $line -Encoding utf8
}

function Read-Configuration {
    param([string]$Path, [ValidateSet('Host', 'Server')][string]$Role)
    $config = Read-JsonFile $Path
    foreach ($name in @('RootCaSha256', 'IssuingCaSha256')) {
        if ($config.$name -cnotmatch '^[A-F0-9]{64}$') { throw "Invalid $name." }
    }
    if ($config.MaximumValidityDays -lt 2 -or $config.MaximumValidityDays -gt 397 -or
        $config.RenewBeforeDays -lt 7 -or $config.RenewBeforeDays -ge $config.MaximumValidityDays) {
        throw 'Use MaximumValidityDays 8-397 and RenewBeforeDays 7 or greater, below the maximum validity.'
    }
    if ($Role -eq 'Host') {
        if (-not (Get-OptionalValue $config DnsName)) {
            Assert-DnsName "host.$($config.DnsSuffix)"
            $config | Add-Member -NotePropertyName DnsName -NotePropertyValue "$($env:COMPUTERNAME.ToLowerInvariant()).$($config.DnsSuffix)"
        }
        Assert-DnsName $config.DnsName
        if ($config.DnsName.Split('.')[0] -ine $env:COMPUTERNAME) {
            throw 'The authorized FQDN must start with this session host computer name.'
        }
        $uri = [Uri]$config.EnrollmentUrl
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
            $uri.AbsolutePath -ne '/enrollment/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
            throw 'EnrollmentUrl must be an HTTPS URL ending in /enrollment/, without credentials or a query.'
        }
        if ($config.RdpPort -lt 1 -or $config.RdpPort -gt 65535) { throw 'Invalid RdpPort.' }
    }
    else {
        $uri = [Uri]$config.Prefix
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
            $uri.AbsolutePath -ne '/enrollment/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
            throw 'Prefix must be an explicit HTTPS URL ending in /enrollment/.'
        }
        Assert-DnsName $uri.DnsSafeHost
        if ($config.CaConfig -notmatch '^[^\\]+\\[^\\]+$' -or
            $config.CaConfig.Split('\')[0] -ine $env:COMPUTERNAME) {
            throw 'CaConfig must identify the local CA as COMPUTERNAME\CA common name.'
        }
        $names = @{}
        $keys = @{}
        foreach ($hostEntry in $config.Hosts) {
            Assert-DnsName $hostEntry.DnsName
            if ($hostEntry.EnrollmentPublicKeySha256 -cnotmatch '^[A-F0-9]{64}$' -or
                $names.ContainsKey($hostEntry.DnsName) -or $keys.ContainsKey($hostEntry.EnrollmentPublicKeySha256)) {
                throw 'Each host must have a unique FQDN and unique enrollment public-key SHA-256 hash.'
            }
            $names[$hostEntry.DnsName] = $true
            $keys[$hostEntry.EnrollmentPublicKeySha256] = $true
        }
        if ($names.Count -eq 0 -and -not (Test-AutomaticBootstrap $config)) { throw 'The server host allowlist is empty.' }
        if (Test-AutomaticBootstrap $config) {
            $bootstrap = $config.Bootstrap
            foreach ($value in @($bootstrap.ArmEndpoint, $bootstrap.ArmAudience, $bootstrap.ArtifactUri)) {
                $endpoint = [Uri]$value
                if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'https' -or
                    $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) {
                    throw 'Bootstrap endpoints must be explicit HTTPS URLs without credentials, queries or fragments.'
                }
            }
            if (([Uri]$bootstrap.ArmEndpoint).AbsolutePath -ne '/' -or
                $bootstrap.VirtualMachinesResourceGroupId -notmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-z0-9_.()-]{1,90}$' -or
                $bootstrap.HostPoolResourceId -notmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-z0-9_.()-]{1,90}/providers/Microsoft\.DesktopVirtualization/hostPools/[a-z0-9_.-]+$' -or
                $bootstrap.PrepareScriptSha256 -cnotmatch '^[A-F0-9]{64}$' -or
                $bootstrap.MaximumProofAgeMinutes -lt 10 -or $bootstrap.MaximumProofAgeMinutes -gt 1440 -or
                $bootstrap.RetirementGraceMinutes -lt 5 -or $bootstrap.RetirementGraceMinutes -gt 10080) {
                throw 'Invalid automatic bootstrap scope, script pin, proof age or retirement grace period.'
            }
            Assert-DnsName "host.$($bootstrap.DnsSuffix)"
            if (Get-OptionalValue $bootstrap ManagedIdentityClientId) { [void][Guid]::Parse($bootstrap.ManagedIdentityClientId) }
        }
    }
    return $config
}

function Set-KeyPermissions {
    param([string]$KeyName, [switch]$Rdp)
    $key = [CngKey]::Open($KeyName, [CngProvider]::MicrosoftSoftwareKeyStorageProvider, [CngKeyOpenOptions]::MachineKey)
    try { $path = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$($key.UniqueName)" }
    finally { $key.Dispose() }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'
        ))
    }
    if ($Rdp) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-20'), 'Read', 'Allow'
        ))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
}

function New-MachineKey {
    $name = 'FederalAVD-Rdp-' + [Guid]::NewGuid().ToString('N')
    $parameters = [CngKeyCreationParameters]::new()
    $parameters.Provider = [CngProvider]::MicrosoftSoftwareKeyStorageProvider
    $parameters.KeyCreationOptions = [CngKeyCreationOptions]::MachineKey
    $parameters.ExportPolicy = [CngExportPolicies]::None
    $parameters.KeyUsage = [CngKeyUsages]::Signing -bor [CngKeyUsages]::Decryption
    $parameters.Parameters.Add([CngProperty]::new('Length', [BitConverter]::GetBytes(3072), [CngPropertyOptions]::None))
    $key = [CngKey]::Create([CngAlgorithm]::Rsa, $name, $parameters)
    $key.Dispose()
    Set-KeyPermissions $name
    return $name
}

function Open-MachineRsa {
    param([string]$Name)
    $key = [CngKey]::Open($Name, [CngProvider]::MicrosoftSoftwareKeyStorageProvider, [CngKeyOpenOptions]::MachineKey)
    try { return [RSACng]::new($key) }
    finally { $key.Dispose() }
}

function Add-MachineCertificate {
    param([X509Certificate2]$Certificate, [RSA]$Key)
    $withKey = [RSACertificateExtensions]::CopyWithPrivateKey($Certificate, $Key)
    $store = [X509Store]::new('My', [StoreLocation]::LocalMachine)
    try {
        $store.Open([OpenFlags]::ReadWrite)
        $store.Add($withKey)
    }
    finally { $store.Dispose(); $withKey.Dispose() }
}

<#
.SYNOPSIS
    Configures Windows SCHANNEL and .NET Framework cryptographic settings to enforce
    secure network protocol compliance with NIST SP 800-53 Rev 5.

.DESCRIPTION
    This script hardens the Windows SCHANNEL subsystem and .NET Framework TLS settings
    by disabling obsolete protocols and weak cipher suites, enabling strong protocols
    and ciphers, and optionally enforcing FIPS 140 mode.

    Controls addressed:
      SC-8   Transmission Confidentiality and Integrity
      SC-8(1) Cryptographic Protection (transport encryption)
      SC-13  Cryptographic Protection (FIPS-validated algorithms)
      SI-2   Flaw Remediation (removing deprecated/vulnerable protocol support)

    Changes require a reboot to take full effect.

.PARAMETER EnableFipsMode
    When specified, enables the Windows system-wide FIPS 140 algorithm policy
    (HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy).
    NOTE: FIPS mode can break applications that use non-FIPS-validated crypto
    (e.g. some monitoring agents or legacy software). Validate in your environment
    before enabling in production. Default: $false (not enabled).

.PARAMETER ConfigureCipherSuites
    When specified, sets the TLS cipher suite priority order via Group Policy to
    prefer ECDHE+AES-GCM suites and remove CBC/SHA-1 suites from the TLS 1.2 list.
    Default: $false (system-managed order).

.NOTES
    A system reboot is required for protocol and cipher changes to take effect.
    Test in a non-production environment before deploying at scale.

    References:
      NIST SP 800-52 Rev 2 — Guidelines for TLS Implementations
      NIST SP 800-53 Rev 5 — SC-8, SC-8(1), SC-13
      CIS Microsoft Windows 11 Benchmark — Section 18.3 (SCHANNEL)
      https://learn.microsoft.com/en-us/windows-server/security/tls/tls-registry-settings
#>
[CmdletBinding()]
param (
    [switch]$EnableFipsMode,
    [switch]$ConfigureCipherSuites
)

#region Initialization
$Script:Name   = 'Configure-SecureNetworkProtocols'
$Script:LogDir = Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration'
If (-not (Test-Path -Path $Script:LogDir)) { New-Item -Path $Script:LogDir -ItemType Directory -Force | Out-Null }
#endregion

#region Functions
Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Info', 'Warning', 'Error')]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )
    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        $LogFile = Join-Path -Path $Script:LogDir -ChildPath "$Script:Name.log"
        Add-Content $LogFile $Content -ErrorAction SilentlyContinue
    }
    Switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [string]$Path,
        [string]$Name,
        [string]$PropertyType,
        $Value
    )
    If (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    If ($existing) {
        $current = Get-ItemPropertyValue -Path $Path -Name $Name
        If ($Value -ne $current) {
            Write-Log -Message "  UPDATED : $Path\$Name  ($current -> $Value)"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
        } Else {
            Write-Log -Message "  SKIPPED : $Path\$Name  (already $Value)"
        }
    } Else {
        Write-Log -Message "  CREATED : $Path\$Name  = $Value"
        New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
    }
}

Function Disable-SchannelProtocol {
    param([string]$Protocol)
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Protocol"
    Write-Log -Message "[Protocol] Disabling $Protocol (Client + Server)"
    Set-RegistryValue -Path "$base\Client" -Name 'Enabled'           -PropertyType 'DWord' -Value 0
    Set-RegistryValue -Path "$base\Client" -Name 'DisabledByDefault'  -PropertyType 'DWord' -Value 1
    Set-RegistryValue -Path "$base\Server" -Name 'Enabled'           -PropertyType 'DWord' -Value 0
    Set-RegistryValue -Path "$base\Server" -Name 'DisabledByDefault'  -PropertyType 'DWord' -Value 1
}

Function Enable-SchannelProtocol {
    param([string]$Protocol)
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Protocol"
    Write-Log -Message "[Protocol] Enabling $Protocol (Client + Server)"
    Set-RegistryValue -Path "$base\Client" -Name 'Enabled'           -PropertyType 'DWord' -Value 1
    Set-RegistryValue -Path "$base\Client" -Name 'DisabledByDefault'  -PropertyType 'DWord' -Value 0
    Set-RegistryValue -Path "$base\Server" -Name 'Enabled'           -PropertyType 'DWord' -Value 1
    Set-RegistryValue -Path "$base\Server" -Name 'DisabledByDefault'  -PropertyType 'DWord' -Value 0
}

Function Disable-SchannelCipher {
    param([string]$Cipher)
    Write-Log -Message "[Cipher] Disabling '$Cipher'"
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\$Cipher" `
        -Name 'Enabled' -PropertyType 'DWord' -Value 0
}

Function Enable-SchannelCipher {
    param([string]$Cipher)
    Write-Log -Message "[Cipher] Enabling '$Cipher'"
    # -1 as Int32 has bits 0xFFFFFFFF — the SCHANNEL "enabled" marker.
    # Using -1 instead of 0xffffffff ensures the Set-RegistryValue idempotency
    # check works correctly (Get-ItemPropertyValue returns Int32, not UInt32).
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\$Cipher" `
        -Name 'Enabled' -PropertyType 'DWord' -Value -1
}
#endregion

#region Main
Write-Log -Message "Starting '$Script:Name'."
Write-Log -Message "Parameters: EnableFipsMode=$EnableFipsMode, ConfigureCipherSuites=$ConfigureCipherSuites"

# ── Protocols ────────────────────────────────────────────────────────────────
# SC-8(1) / NIST SP 800-52 Rev 2: Disable all deprecated SSL/TLS versions.
# PCT 1.0 and Multi-Protocol Unified Hello are legacy Microsoft pre-SSL protocols.

Write-Log -Message '=== Phase 1: Protocol Configuration ==='

Write-Log -Message '[Protocol] Disabling obsolete protocols (SC-8, SC-8(1), SI-2)'
Disable-SchannelProtocol -Protocol 'Multi-Protocol Unified Hello'
Disable-SchannelProtocol -Protocol 'PCT 1.0'
Disable-SchannelProtocol -Protocol 'SSL 2.0'
Disable-SchannelProtocol -Protocol 'SSL 3.0'

# TLS 1.0 and 1.1 are deprecated per NIST SP 800-52 Rev 2 (Sep 2019).
# Both are prohibited for US federal systems.
Disable-SchannelProtocol -Protocol 'TLS 1.0'
Disable-SchannelProtocol -Protocol 'TLS 1.1'

Write-Log -Message '[Protocol] Enabling required protocols (TLS 1.2, TLS 1.3)'
Enable-SchannelProtocol -Protocol 'TLS 1.2'
Enable-SchannelProtocol -Protocol 'TLS 1.3'

# ── Ciphers ──────────────────────────────────────────────────────────────────
# SC-13: Disable weak / broken symmetric cipher suites.

Write-Log -Message '=== Phase 2: Cipher Configuration ==='

Write-Log -Message '[Cipher] Disabling NULL and export-grade ciphers (SC-13)'
Disable-SchannelCipher -Cipher 'NULL'

Write-Log -Message '[Cipher] Disabling DES (broken, 56-bit key)'
Disable-SchannelCipher -Cipher 'DES 56/56'

Write-Log -Message '[Cipher] Disabling RC2 (broken, variable key)'
Disable-SchannelCipher -Cipher 'RC2 40/128'
Disable-SchannelCipher -Cipher 'RC2 56/128'
Disable-SchannelCipher -Cipher 'RC2 128/128'

Write-Log -Message '[Cipher] Disabling RC4 (broken stream cipher — RFC 7465)'
Disable-SchannelCipher -Cipher 'RC4 40/128'
Disable-SchannelCipher -Cipher 'RC4 56/128'
Disable-SchannelCipher -Cipher 'RC4 64/128'
Disable-SchannelCipher -Cipher 'RC4 128/128'

Write-Log -Message '[Cipher] Disabling Triple-DES (SWEET32 vulnerability — CVE-2016-2183)'
Disable-SchannelCipher -Cipher 'Triple DES 168'

Write-Log -Message '[Cipher] Ensuring AES is enabled (SC-13)'
Enable-SchannelCipher -Cipher 'AES 128/128'
Enable-SchannelCipher -Cipher 'AES 256/256'

# ── Hashes ───────────────────────────────────────────────────────────────────
# SC-13: MD5 is cryptographically broken (collision attacks).
# SHA-1 is deprecated by NIST (SP 800-131A Rev 2) for digital signatures.

Write-Log -Message '=== Phase 3: Hash Configuration ==='
Write-Log -Message '[Hash] Disabling MD5 (collision attacks, not FIPS approved for signatures)'
Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hashes\MD5' `
    -Name 'Enabled' -PropertyType 'DWord' -Value 0

Write-Log -Message '[Hash] Ensuring SHA-256 and SHA-384 are enabled'
Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hashes\SHA256' `
    -Name 'Enabled' -PropertyType 'DWord' -Value -1
Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hashes\SHA384' `
    -Name 'Enabled' -PropertyType 'DWord' -Value -1
Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hashes\SHA512' `
    -Name 'Enabled' -PropertyType 'DWord' -Value -1

# ── .NET Framework TLS ───────────────────────────────────────────────────────
# Without these settings, .NET apps may negotiate TLS 1.0/1.1 even when SCHANNEL
# has them disabled, because legacy .NET defaults can override SCHANNEL settings.
# SystemDefaultTlsVersions=1 defers to SCHANNEL; SchUseStrongCrypto=1 disables
# weak algorithms at the .NET layer.

Write-Log -Message '=== Phase 4: .NET Framework TLS Hardening ==='
foreach ($fw in @('v4.0.30319', 'v2.0.50727')) {
    foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\.NETFramework', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework')) {
        $path = "$hive\$fw"
        Write-Log -Message "[.NET] $path — SystemDefaultTlsVersions + SchUseStrongCrypto"
        Set-RegistryValue -Path $path -Name 'SystemDefaultTlsVersions' -PropertyType 'DWord' -Value 1
        Set-RegistryValue -Path $path -Name 'SchUseStrongCrypto'        -PropertyType 'DWord' -Value 1
    }
}

# ── Cipher Suite Order (optional) ────────────────────────────────────────────
# SC-13: Prefer ECDHE+AES-GCM (forward secrecy, authenticated encryption).
# Removes CBC+SHA suites from TLS 1.2 negotiation to eliminate potential
# BEAST/LUCKY13 attack surface. TLS 1.3 suites are controlled by Windows
# natively and are not affected by this policy.

if ($ConfigureCipherSuites) {
    Write-Log -Message '=== Phase 5: Cipher Suite Order (SC-13) ==='
    $suites = @(
        # TLS 1.3 (Windows manages these natively but listing for clarity)
        'TLS_AES_256_GCM_SHA384',
        'TLS_AES_128_GCM_SHA256',
        'TLS_CHACHA20_POLY1305_SHA256',
        # TLS 1.2 — ECDHE + AES-GCM (forward secrecy + AEAD)
        'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
        'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
        'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
        'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
        # TLS 1.2 — DHE + AES-GCM (forward secrecy + AEAD, no elliptic curve)
        'TLS_DHE_RSA_WITH_AES_256_GCM_SHA384',
        'TLS_DHE_RSA_WITH_AES_128_GCM_SHA256'
    )
    $suiteList = $suites -join ','
    Write-Log -Message "[CipherSuites] Setting policy order: $suiteList"
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002' `
        -Name 'Functions' -PropertyType 'String' -Value $suiteList
    Write-Log -Message '[CipherSuites] NOTE: A reboot is required for the cipher suite order to take effect.'
}

# ── FIPS 140 Mode (optional) ─────────────────────────────────────────────────
# SC-13: Restricts all Windows cryptographic operations to FIPS 140-validated
# algorithms. Enforces the most restrictive compliance posture.
# WARNING: Enabling FIPS mode may break applications that use non-FIPS crypto.
# Validate against all installed software before enabling in production.

if ($EnableFipsMode) {
    Write-Log -Message '=== Phase 6: FIPS 140 Mode (SC-13) ==='
    Write-Log -Message '[FIPS] Enabling system-wide FIPS algorithm policy'
    Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy' `
        -Name 'Enabled' -PropertyType 'DWord' -Value 1
    Write-Log -Category 'Warning' -Message '[FIPS] FIPS mode enabled. Some applications using non-FIPS crypto will fail. Reboot required.'
} else {
    Write-Log -Message '[FIPS] Skipping FIPS mode (EnableFipsMode not specified).'
}

Write-Log -Message "Completed '$Script:Name'. A system reboot is required for all changes to take effect."
#endregion

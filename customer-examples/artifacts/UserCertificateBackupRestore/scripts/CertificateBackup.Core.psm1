#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CertificateSignIn.Core.psm1') -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Set-FileZone.ps1')

function Get-CertificateBackupIdentity {
    param([Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $template = ''
    $ekus = [Collections.Generic.List[string]]::new()
    foreach ($extension in $Certificate.Extensions) {
        if ($extension -is [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and
            $extension.CertificateAuthority) { throw 'Certificate-authority keys cannot be backed up by this user-identity helper.' }
        if ($extension.Oid.Value -in '1.3.6.1.4.1.311.21.7', '1.3.6.1.4.1.311.20.2') {
            $template += $extension.Oid.Value + ':' + [Convert]::ToBase64String($extension.RawData) + ';'
        }
        if ($extension -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            foreach ($oid in $extension.EnhancedKeyUsages) { $ekus.Add($oid.Value) }
        }
    }
    $selector = @(
        [Convert]::ToBase64String($Certificate.SubjectName.RawData),
        [Convert]::ToBase64String($Certificate.IssuerName.RawData),
        $template, (($ekus | Sort-Object) -join ',')
    ) -join '|'
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $identityId = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($selector))).Replace('-', '') }
    finally { $hash.Dispose() }
    return [pscustomobject]@{
        Thumbprint = $Certificate.Thumbprint
        IdentityId = $identityId
        Subject = $Certificate.Subject
        Issuer = $Certificate.Issuer
        NotBeforeUtc = $Certificate.NotBefore.ToUniversalTime().ToString('o')
        NotAfterUtc = $Certificate.NotAfter.ToUniversalTime().ToString('o')
    }
}

function Get-UserBackupCertificates {
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('My',
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $snapshot = $null
    try {
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $snapshot = $store.Certificates
        foreach ($certificate in $snapshot) {
            if (-not $certificate.HasPrivateKey -or
                $certificate.PublicKey.Oid.Value -notin '1.2.840.113549.1.1.1', '1.2.840.10045.2.1') { continue }
            $isCa = $false
            foreach ($extension in $certificate.Extensions) {
                if ($extension -is [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and
                    $extension.CertificateAuthority) { $isCa = $true }
            }
            if (-not $isCa) { Get-CertificateBackupIdentity $certificate }
        }
    } finally {
        if ($null -ne $snapshot) { foreach ($certificate in $snapshot) { $certificate.Dispose() } }
        $store.Dispose()
    }
}

function Get-CertificateBackupStatus {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [object[]]$Certificates,
        [ValidateRange(1, 365)][int]$ExpiryWarningDays = 30
    )
    if ([string]::IsNullOrWhiteSpace($Folder)) { throw 'Choose a backup folder.' }
    $Folder = [IO.Path]::GetFullPath((Resolve-CertificateInputPath -DefaultInputPath $Folder))
    if (-not $PSBoundParameters.ContainsKey('Certificates')) { $Certificates = @(Get-UserBackupCertificates) }
    $manifest = Get-CertificateBackupManifest $Folder
    $warnings = [Collections.Generic.List[string]]::new()
    $renewals = [Collections.Generic.List[string]]::new()
    $approved = @()
    if ($null -eq $manifest) {
        $warnings.Add('No managed backup yet. Select the identities you want to protect in Back up certificates.')
    } else {
        [void](Get-ManagedCertificateBackupPath -Folder $Folder -Manifest $manifest)
        $approved = @($manifest.Certificates | ForEach-Object { $_.Thumbprint })
        foreach ($identity in $manifest.Certificates) {
            $expires = [DateTimeOffset]::Parse($identity.NotAfterUtc, [Globalization.CultureInfo]::InvariantCulture)
            if ($expires.UtcDateTime -le [DateTime]::UtcNow.AddDays($ExpiryWarningDays)) {
                $warnings.Add("Expires within $ExpiryWarningDays days or is expired: $($identity.Subject) ($($identity.Thumbprint)).")
            }
            if (@($Certificates | Where-Object Thumbprint -EQ $identity.Thumbprint).Count -eq 0) {
                $warnings.Add("Previously selected identity is not in this user store: $($identity.Subject).")
            }
            foreach ($candidate in $Certificates) {
                if ($candidate.IdentityId -eq $identity.IdentityId -and $candidate.Thumbprint -notin $approved -and
                    [DateTimeOffset]::Parse($candidate.NotBeforeUtc) -gt [DateTimeOffset]::Parse($identity.NotBeforeUtc)) {
                    if (-not $renewals.Contains($candidate.Thumbprint)) {
                        $renewals.Add($candidate.Thumbprint)
                        $warnings.Add("Possible renewal: $($candidate.Subject) ($($candidate.Thumbprint)). Review before backing up.")
                    }
                }
            }
        }
    }
    return [pscustomobject]@{
        Manifest = $manifest
        NeedsAttention = $warnings.Count -gt 0
        Warnings = $warnings.ToArray()
        ApprovedThumbprints = $approved
        RenewalThumbprints = $renewals.ToArray()
    }
}

function New-CertificateBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [Security.Cryptography.X509Certificates.X509Certificate2[]]$Certificates,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$Folder
    )
    if ($Password.Length -lt 12) { throw 'New backups require a password of at least 12 characters. Use a long, unique passphrase, not a PIN.' }
    if ($Certificates.Count -gt 128) { throw 'Select at most 128 identities.' }
    $Folder = [IO.Path]::GetFullPath((Resolve-CertificateInputPath -DefaultInputPath $Folder))
    $identities = @($Certificates | ForEach-Object {
        if (-not $_.HasPrivateKey) { throw 'Every selected certificate must have a private key.' }
        Assert-CertificatePrivateKey $_
        Get-CertificateBackupIdentity $_
    })
    $thumbprints = @($identities | ForEach-Object { $_.Thumbprint })
    if (@($thumbprints | Sort-Object -Unique).Count -ne $thumbprints.Count) { throw 'A certificate was selected more than once.' }
    $name = 'CertificateSignIn-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
    $staging = Join-Path $Folder ($name + '.pending')
    $final = Join-Path $Folder ($name + '.pfx')
    $manifestPath = Join-Path $Folder 'CertificateSignIn.backup.json'
    $manifestStaging = Join-Path $Folder ($name + '.pending.json')
    $legacyStaging = Join-Path $Folder ($name + '.legacy.pending')
    $before = @()
    if ([IO.Directory]::Exists($Folder)) {
        $before = @(Get-ChildItem -LiteralPath $Folder -Recurse -Force -File | Select-Object FullName, Length, LastWriteTimeUtc)
    }
    $cryptoBefore = Get-CertificateFileInventory
    $written = @($staging, $final, $manifestPath, $manifestStaging, $legacyStaging)
    $manifestZone = if ([IO.File]::Exists($manifestPath) -and (Read-ZoneId $manifestPath) -eq 4) { 4 } else { 3 }
    $bytes = $null
    $legacyBytes = $null
    $pfxData = $null
    try {
        [void][IO.Directory]::CreateDirectory($Folder)
        $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        foreach ($certificate in $Certificates) { [void]$collection.Add($certificate) }
        # The Windows cmdlet accepts a PfxData bundle, not an array of certificate objects.
        $buffer = [IntPtr]::Zero
        $plainText = $null
        try {
            $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer)
            $legacyBytes = $collection.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $plainText)
        } finally {
            $plainText = $null
            if ($buffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) }
        }
        [IO.File]::WriteAllBytes($legacyStaging, $legacyBytes)
        Set-FileZone $legacyStaging
        $pfxData = Get-PfxData -FilePath $legacyStaging -Password $Password -ErrorAction Stop
        Export-PfxCertificate -PFXData $pfxData -FilePath $staging -Password $Password -CryptoAlgorithmOption AES256_SHA256 `
            -ChainOption PfxDataOnly -ErrorAction Stop | Out-Null
        Set-FileZone $staging
        if ([IO.FileInfo]::new($staging).Length -gt 32MB) { throw 'The exported bundle exceeds the 32 MB restore limit.' }
        $bytes = [IO.File]::ReadAllBytes($staging)
        Assert-CertificateBundle -Bytes $bytes -Password $Password -ExpectedThumbprints $thumbprints
        $manifest = [ordered]@{
            SchemaVersion = 1
            BackupFile = [IO.Path]::GetFileName($final)
            Sha256 = Get-CertificateFileHash $staging
            CreatedUtc = [DateTime]::UtcNow.ToString('o')
            Certificates = $identities
        }
        [IO.File]::Move($staging, $final)
        Set-FileZone $final
        try {
            [IO.File]::WriteAllText($manifestStaging, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
            Set-FileZone $manifestStaging $manifestZone
            if ([IO.File]::Exists($manifestPath)) {
                [IO.File]::Replace($manifestStaging, $manifestPath, [Management.Automation.Language.NullString]::Value)
            }
            else { [IO.File]::Move($manifestStaging, $manifestPath) }
            Set-FileZone $manifestPath $manifestZone
        } catch { throw "PFX saved at $final, but publishing its manifest failed. The previous managed selection remains unchanged if replacement did not complete. $($_.Exception.Message)" }
        return [pscustomobject]@{ Path = $final; Count = $identities.Count; CreatedUtc = $manifest.CreatedUtc }
    } catch {
        throw "Backup failed; no earlier PFX was deleted. Check destination availability/write permissions and ensure every selected key is exportable under the issuing PKI/provider policy. $($_.Exception.Message)"
    } finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($null -ne $legacyBytes) { [Array]::Clear($legacyBytes, 0, $legacyBytes.Length) }
        if ($null -ne $pfxData) {
            foreach ($certificate in @($pfxData.EndEntityCertificates) + @($pfxData.OtherCertificates)) {
                if ($null -ne $certificate) { $certificate.Dispose() }
            }
        }
        if ([IO.Directory]::Exists($Folder)) {
            foreach ($file in Get-ChildItem -LiteralPath $Folder -Recurse -Force -File) {
                $old = $before | Where-Object FullName -EQ $file.FullName | Select-Object -First 1
                if ($file.FullName -in $written -or -not $old -or $old.Length -ne $file.Length -or
                    $old.LastWriteTimeUtc -ne $file.LastWriteTimeUtc) { Set-FileZone $file.FullName }
            }
        }
        $cryptoAfter = Get-CertificateFileInventory
        foreach ($path in $cryptoAfter.Keys) {
            if (-not $cryptoBefore.ContainsKey($path) -or $cryptoBefore[$path].Length -ne $cryptoAfter[$path].Length -or
                $cryptoBefore[$path].Ticks -ne $cryptoAfter[$path].Ticks) { Set-FileZone $path }
        }
        foreach ($temporary in @($staging, $manifestStaging, $legacyStaging)) {
            if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -ErrorAction Stop }
        }
    }
}

function Backup-UserCertificates {
    param(
        [Parameter(Mandatory)][string[]]$Thumbprints,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$Folder
    )
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('My',
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $snapshot = $null
    $previous = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $previousBytes = $null
    try {
        $Folder = [IO.Path]::GetFullPath((Resolve-CertificateInputPath -DefaultInputPath $Folder))
        $manifest = Get-CertificateBackupManifest $Folder
        if ($null -ne $manifest -and @($manifest.Certificates | Where-Object { $_.Thumbprint -in $Thumbprints }).Count -gt 0) {
            $previousPath = Get-ManagedCertificateBackupPath -Folder $Folder -Manifest $manifest
            $previousBytes = [IO.File]::ReadAllBytes($previousPath)
            try {
                Assert-CertificateBundle -Bytes $previousBytes -Password $Password -ExpectedThumbprints @($manifest.Certificates | ForEach-Object { $_.Thumbprint })
                # Reuse keys already present in the user's encrypted backup; never relax a stored key's policy.
                $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet -bor
                    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
                Import-CertificateCollection $previous $previousBytes $Password $flags
            } catch { throw "Enter the existing managed backup's password to retain its identities. No stored key policy was changed. $($_.Exception.Message)" }
        }
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $snapshot = $store.Certificates
        $selected = [Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]]::new()
        foreach ($thumbprint in @($Thumbprints | Sort-Object -Unique)) {
            $match = @($previous | Where-Object { $_.HasPrivateKey -and $_.Thumbprint -eq $thumbprint })
            if ($match.Count -eq 0) { $match = @($snapshot | Where-Object { $_.HasPrivateKey -and $_.Thumbprint -eq $thumbprint }) }
            if ($match.Count -ne 1) { throw 'A selected certificate is unavailable in both the user store and the existing managed backup. Refresh and review the selection.' }
            $selected.Add($match[0])
        }
        New-CertificateBackup -Certificates $selected.ToArray() -Password $Password -Folder $Folder
    } finally {
        if ($null -ne $previousBytes) { [Array]::Clear($previousBytes, 0, $previousBytes.Length) }
        foreach ($certificate in $previous) { $certificate.Dispose() }
        if ($null -ne $snapshot) { foreach ($certificate in $snapshot) { $certificate.Dispose() } }
        $store.Dispose()
    }
}

Export-ModuleMember -Function Get-CertificateBackupIdentity, Get-UserBackupCertificates, Get-CertificateBackupStatus,
    New-CertificateBackup, Backup-UserCertificates

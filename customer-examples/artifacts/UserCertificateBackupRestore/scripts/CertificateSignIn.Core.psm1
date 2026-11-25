#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Set-FileZone.ps1')

function Find-NewestCertificate {
    param([AllowEmptyString()][string]$InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Choose a certificate folder first.' }
    $folder = Resolve-CertificateInputPath -DefaultInputPath $InputPath
    if (-not [IO.Directory]::Exists($folder)) { throw "The certificate folder is unavailable: $folder" }
    $manifest = Get-CertificateBackupManifest $folder
    if ($null -ne $manifest) { return Get-ManagedCertificateBackupPath -Folder $folder -Manifest $manifest }
    $newest = $null
    foreach ($path in [IO.Directory]::EnumerateFiles($folder)) {
        if ([IO.Path]::GetExtension($path) -notin '.pfx', '.p12') { continue }
        $file = [IO.FileInfo]::new($path)
        if ($null -eq $newest -or $file.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc -or
            ($file.LastWriteTimeUtc -eq $newest.LastWriteTimeUtc -and
             [StringComparer]::OrdinalIgnoreCase.Compare($file.FullName, $newest.FullName) -lt 0)) {
            $newest = $file
        }
    }
    if ($null -eq $newest) { throw 'No .pfx or .p12 files were found. Subfolders are not searched.' }
    return $newest.FullName
}

function Assert-CertificatePrivateKey {
    param([Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $challenge = [byte[]]::new(32)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($challenge) } finally { $random.Dispose() }
    $private = $null
    $public = $null
    try {
        $private = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
        if ($null -ne $private) {
            $public = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
            $signature = $private.SignData($challenge, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            if (-not $public.VerifyData($challenge, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'RSA private-key verification failed.' }
            return
        }
        $private = [Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate)
        if ($null -ne $private) {
            $public = [Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($Certificate)
            $signature = $private.SignData($challenge, [Security.Cryptography.HashAlgorithmName]::SHA256)
            if (-not $public.VerifyData($challenge, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256)) {
                throw 'ECDSA private-key verification failed.'
            }
            return
        }
        throw 'Only RSA and ECDSA private-key certificates are supported.'
    } finally {
        if ($null -ne $public) { $public.Dispose() }
        if ($null -ne $private) { $private.Dispose() }
    }
}

function Assert-CertificateBundle {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [string[]]$ExpectedThumbprints
    )
    $bundle = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    try {
        Import-CertificateCollection $bundle $Bytes $Password ([Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        $count = 0
        $thumbprints = [Collections.Generic.List[string]]::new()
        foreach ($certificate in $bundle) {
            if (-not $certificate.HasPrivateKey) { continue }
            foreach ($extension in $certificate.Extensions) {
                if ($extension -is [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and
                    $extension.CertificateAuthority) { throw 'Certificate-authority private keys are not supported.' }
            }
            Assert-CertificatePrivateKey $certificate
            $count++
            $thumbprints.Add($certificate.Thumbprint)
        }
        if ($count -eq 0) { throw 'The bundle does not contain a usable private-key certificate.' }
        if ($ExpectedThumbprints) {
            $actual = @($thumbprints | Sort-Object -Unique)
            $expected = @($ExpectedThumbprints | Sort-Object -Unique)
            if ($actual.Count -ne $expected.Count -or @(Compare-Object $actual $expected).Count -ne 0) {
                throw 'The exported bundle does not contain every selected private-key identity.'
            }
        }
    } finally {
        foreach ($certificate in $bundle) { $certificate.Dispose() }
    }
}

function Get-CertificateFileHash {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
    finally { $hash.Dispose(); $stream.Dispose() }
}

function Get-CertificateBackupManifest {
    param([Parameter(Mandatory)][string]$Folder)
    $path = Join-Path $Folder 'CertificateSignIn.backup.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    if ([IO.FileInfo]::new($path).Length -gt 256KB) { throw 'The backup manifest is too large.' }
    $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('SchemaVersion', 'BackupFile', 'Sha256', 'CreatedUtc', 'Certificates')) {
        if ($null -eq $manifest -or $null -eq $manifest.PSObject.Properties[$field]) { throw "Invalid backup manifest: missing $field." }
    }
    if ($manifest.SchemaVersion -ne 1 -or $manifest.BackupFile -isnot [string] -or
        $manifest.BackupFile -notmatch '^CertificateSignIn-[A-Za-z0-9-]+\.pfx$' -or
        $manifest.Sha256 -isnot [string] -or $manifest.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Invalid backup manifest version, filename, or hash.'
    }
    [void][DateTimeOffset]::Parse($manifest.CreatedUtc, [Globalization.CultureInfo]::InvariantCulture)
    if (@($manifest.Certificates).Count -eq 0 -or @($manifest.Certificates).Count -gt 128) {
        throw 'Invalid backup manifest certificate selection.'
    }
    foreach ($certificate in $manifest.Certificates) {
        foreach ($field in @('Thumbprint', 'IdentityId', 'Subject', 'Issuer', 'NotBeforeUtc', 'NotAfterUtc')) {
            if ($null -eq $certificate.PSObject.Properties[$field] -or $certificate.$field -isnot [string]) {
                throw "Invalid backup certificate metadata: $field."
            }
        }
        if ($certificate.Thumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or $certificate.IdentityId -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Invalid backup certificate identity.'
        }
        [void][DateTimeOffset]::Parse($certificate.NotBeforeUtc, [Globalization.CultureInfo]::InvariantCulture)
        [void][DateTimeOffset]::Parse($certificate.NotAfterUtc, [Globalization.CultureInfo]::InvariantCulture)
    }
    if (@($manifest.Certificates | ForEach-Object { $_.Thumbprint } | Sort-Object -Unique).Count -ne @($manifest.Certificates).Count) {
        throw 'Invalid backup manifest: duplicate selected identity.'
    }
    return $manifest
}

function Get-ManagedCertificateBackupPath {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)]$Manifest)
    $path = Join-Path $Folder $Manifest.BackupFile
    if (-not [IO.File]::Exists($path)) { throw "The last validated backup is missing: $path" }
    if ([IO.FileInfo]::new($path).Length -gt 32MB) { throw 'The managed backup exceeds 32 MB.' }
    if ((Get-CertificateFileHash $path) -ne $Manifest.Sha256) { throw 'The managed backup hash does not match. Do not restore it; investigate or create a fresh validated backup.' }
    return $path
}

function Import-CertificateCollection {
    param(
        [Security.Cryptography.X509Certificates.X509Certificate2Collection]$Collection,
        [byte[]]$Bytes,
        [Security.SecureString]$Password,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]$Flags
    )
    # .NET Framework's collection importer has no SecureString overload.
    $buffer = [IntPtr]::Zero
    $plainText = $null
    try {
        $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer)
        $Collection.Import($Bytes, $plainText, $Flags)
    } finally {
        $plainText = $null
        if ($buffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) }
    }
}

function Get-CertificateFileInventory {
    $inventory = @{}
    $roots = @(
        (Join-Path $env:APPDATA 'Microsoft\Crypto'),
        (Join-Path $env:APPDATA 'Microsoft\SystemCertificates'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Crypto'),
        (Join-Path $env:APPDATA 'Microsoft\Protect')
    )
    foreach ($root in $roots) {
        if ([IO.Directory]::Exists($root)) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction Stop) {
                $inventory[$file.FullName] = [pscustomobject]@{
                    Length = $file.Length
                    Ticks = $file.LastWriteTimeUtc.Ticks
                }
            }
        }
    }
    return $inventory
}

function Import-UserCertificate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Security.SecureString]$Password
    )
    $before = Get-CertificateFileInventory
    $bytes = $null
    $bundle = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('My',
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        if ([IO.FileInfo]::new($Path).Length -gt 32MB) { throw 'Certificate bundles larger than 32 MB are not supported.' }
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -eq 0) { throw 'The certificate file is empty.' }
        $expected = @()
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        $manifest = Get-CertificateBackupManifest $parent
        if ($null -ne $manifest) {
            $managed = Get-ManagedCertificateBackupPath -Folder $parent -Manifest $manifest
            if ([IO.Path]::GetFullPath($Path) -ne $managed) { throw 'The selected file is not the current managed backup.' }
            $hash = [Security.Cryptography.SHA256]::Create()
            try {
                $loadedHash = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '')
                if ($loadedHash -ne $manifest.Sha256) { throw 'The managed backup changed during import. No keys were persisted.' }
            } finally { $hash.Dispose() }
            $expected = @($manifest.Certificates | ForEach-Object { $_.Thumbprint })
        }
        Assert-CertificateBundle -Bytes $bytes -Password $Password -ExpectedThumbprints $expected
        $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet -bor
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
        Import-CertificateCollection $bundle $bytes $Password $flags
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $results = [Collections.Generic.List[string]]::new()
        foreach ($certificate in $bundle) {
            if (-not $certificate.HasPrivateKey) { continue }
            $store.Add($certificate)
            $snapshot = $store.Certificates
            $matches = $null
            try {
                $matches = $snapshot.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                    $certificate.Thumbprint, $false)
                if ($matches.Count -eq 0) { throw 'The imported certificate could not be read back from the user store.' }
                Assert-CertificatePrivateKey $matches[0]
            } finally {
                if ($null -ne $matches) { foreach ($item in $matches) { $item.Dispose() } }
                foreach ($item in $snapshot) { $item.Dispose() }
            }
            $warning = ''
            if ([DateTime]::Now -gt $certificate.NotAfter) { $warning = ' [EXPIRED]' }
            elseif ([DateTime]::Now -lt $certificate.NotBefore) { $warning = ' [NOT YET VALID]' }
            $results.Add(('{0}{1}Thumbprint: {2}{1}Expires: {3}{4}' -f $certificate.Subject,
                [Environment]::NewLine, $certificate.Thumbprint, $certificate.NotAfter.ToString('g'), $warning))
        }
        return $results.ToArray()
    } finally {
        $store.Dispose()
        foreach ($certificate in $bundle) { $certificate.Dispose() }
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        $after = Get-CertificateFileInventory
        foreach ($pathWritten in $after.Keys) {
            if (-not $before.ContainsKey($pathWritten) -or
                $before[$pathWritten].Length -ne $after[$pathWritten].Length -or
                $before[$pathWritten].Ticks -ne $after[$pathWritten].Ticks) {
                Set-FileZone $pathWritten
            }
        }
    }
}

function Get-CertificateSettingsPath {
    return Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'CertificateSignIn\settings.json'
}

function Open-CertificateSettingsKey {
    param([switch]$Writable)
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
    try {
        if ($Writable) { return $baseKey.CreateSubKey('Software\CertificateSignIn') }
        return $baseKey.OpenSubKey('Software\CertificateSignIn', $false)
    } finally { $baseKey.Dispose() }
}

function Get-CertificateSettings {
    param([Microsoft.Win32.RegistryKey]$RegistryKey, [switch]$IncludeSource)
    $ownsKey = $null -eq $RegistryKey
    try {
        if ($ownsKey) { $RegistryKey = Open-CertificateSettingsKey }
        if ($null -ne $RegistryKey) {
            $value = $RegistryKey.GetValue('InputPath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $value) {
                if ($RegistryKey.GetValueKind('InputPath') -notin [Microsoft.Win32.RegistryValueKind]::String,
                    [Microsoft.Win32.RegistryValueKind]::ExpandString -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                    throw 'Saved InputPath must be a nonempty REG_SZ or REG_EXPAND_SZ under HKCU\Software\CertificateSignIn.'
                }
                if ($IncludeSource) { return [pscustomobject]@{ InputPath = $value; Source = 'Saved' } }
                return $value
            }
        }
    } finally {
        if ($ownsKey -and $null -ne $RegistryKey) { $RegistryKey.Dispose() }
    }
    # Keep existing installations usable; new saves go only to HKCU.
    $path = Get-CertificateSettingsPath
    if (-not [IO.File]::Exists($path)) {
        if ($IncludeSource) { return [pscustomobject]@{ InputPath = ''; Source = 'Default' } }
        return ''
    }
    $settings = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $settings -or $null -eq $settings.PSObject.Properties['InputPath'] -or
        $settings.InputPath -isnot [string]) { throw 'Saved settings must contain a string InputPath.' }
    if ($IncludeSource) {
        $source = if ([string]::IsNullOrWhiteSpace($settings.InputPath)) { 'Default' } else { 'Legacy' }
        return [pscustomobject]@{ InputPath = $settings.InputPath; Source = $source }
    }
    return $settings.InputPath
}

function Resolve-CertificateInputPath {
    param(
        [string]$InputPath,
        [string]$SavedInputPath,
        [Parameter(Mandatory)][string]$DefaultInputPath,
        [string]$ManagedInputPath,
        [switch]$PreserveEnvironmentReferences
    )
    $selected = $DefaultInputPath
    if (-not [string]::IsNullOrWhiteSpace($SavedInputPath)) { $selected = $SavedInputPath }
    if (-not [string]::IsNullOrWhiteSpace($InputPath)) { $selected = $InputPath }
    $managed = -not [string]::IsNullOrWhiteSpace($ManagedInputPath)
    if ($managed) { $selected = $ManagedInputPath }
    if ([string]::IsNullOrWhiteSpace($selected)) { throw 'A default certificate backup folder is required.' }
    $expanded = [Environment]::ExpandEnvironmentVariables($selected.Trim())
    if ($managed) {
        if ($expanded -match '%[^%]+%' -or $expanded.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
            $expanded -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))' -or $expanded -match '^\\\\[?.]\\') {
            throw 'Managed certificate folders must be absolute drive or UNC paths without invalid characters or unresolved environment variables.'
        }
        $expanded = [IO.Path]::GetFullPath($expanded)
    }
    if ($PreserveEnvironmentReferences -and -not $managed) { return $selected.Trim() }
    if ($expanded -match '%[^%]+%') {
        throw "The certificate folder contains an unresolved environment variable: $expanded. Make sure the variable is available in this user's application session. For OneDriveCommercial, configure and sign in to work OneDrive, then relaunch the tool from a session with that variable available. No alternate folder was selected."
    }
    return $expanded
}

function Get-CertificateFolderPresentation {
    param(
        [Parameter(Mandatory)][ValidateSet('Restore', 'Backup')][string]$Role,
        [Parameter(Mandatory)][ValidateSet('Managed', 'Saved', 'Legacy', 'Default', 'Explicit', 'Custom')][string]$Source,
        [switch]$Startup,
        [switch]$ExplicitInputPath
    )
    $action = if ($Role -eq 'Restore') { 'Restore certificates' } else { 'Back up certificates' }
    $folderRole = $Role.ToLowerInvariant()
    $labels = @{
        Managed = "Organization-managed $folderRole folder"
        Saved = "Your saved $folderRole folder (HKCU)"
        Legacy = "Previous $folderRole folder (legacy settings)"
        Default = "Default $folderRole folder"
        Explicit = "Launch-supplied $folderRole folder"
        Custom = "Changed $folderRole folder (not remembered)"
    }
    $hints = @{
        Managed = 'Folder locked by your organization. Contact your administrator to change it.'
        Saved = 'Saved in HKCU. Edit or browse, then Remember folder to update your choice.'
        Legacy = 'Using previous JSON settings. Remember folder saves your choice in HKCU.'
        Default = 'Using the deployment fallback. Choose a folder, then Remember folder to save it.'
        Explicit = 'Supplied at launch. You can save HKCU, but this launch path still wins next time.'
        Custom = 'Not remembered yet. Remember folder saves this choice in HKCU for both tools.'
    }
    $saveText = 'Remember folder'
    if ($Source -eq 'Managed') {
        $saveText = if ($Role -eq 'Restore' -and -not $Startup) { 'Save startup option' } else { 'Managed folder' }
    }
    $hint = $hints[$Source]
    if ($ExplicitInputPath -and $Source -in 'Saved', 'Custom') {
        $hint = 'Remember folder writes HKCU, but this shortcut or launch path still wins next time.'
    }
    return [pscustomobject]@{
        WindowTitle = "$action - User Certificate Backup & Restore"
        FolderTitle = $labels[$Source]
        Hint = $hint
        SaveText = $saveText
    }
}

function Get-CertificatePolicy {
    param([Microsoft.Win32.RegistryKey]$RegistryKey)
    $baseKey = $null
    $ownsKey = $null -eq $RegistryKey
    try {
        if ($ownsKey) {
            $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $RegistryKey = $baseKey.OpenSubKey('Software\Policies\CertificateSignIn', $false)
        }
        $values = @{ RestoreFolder = $null; BackupFolder = $null; ExpiryWarningDays = $null }
        if ($null -ne $RegistryKey) {
            foreach ($name in @('RestoreFolder', 'BackupFolder')) {
                $value = $RegistryKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $value) { continue }
                if ($RegistryKey.GetValueKind($name) -notin [Microsoft.Win32.RegistryValueKind]::String,
                    [Microsoft.Win32.RegistryValueKind]::ExpandString -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                    throw "Managed $name must be a nonempty REG_SZ or REG_EXPAND_SZ value."
                }
                $values[$name] = Resolve-CertificateInputPath -ManagedInputPath $value -DefaultInputPath $value
            }
            $expiry = $RegistryKey.GetValue('ExpiryWarningDays', $null)
            if ($null -ne $expiry) {
                if ($RegistryKey.GetValueKind('ExpiryWarningDays') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
                    $expiry -isnot [int] -or $expiry -lt 1 -or $expiry -gt 365) {
                    throw 'Managed ExpiryWarningDays must be a REG_DWORD integer from 1 to 365.'
                }
                $values.ExpiryWarningDays = $expiry
            }
        }
        return [pscustomobject]$values
    } finally {
        if ($ownsKey -and $null -ne $RegistryKey) { $RegistryKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Test-CertificateFormCloseAllowed {
    param([bool]$Startup, [bool]$Busy, [bool]$Verified)
    return -not $Busy -and (-not $Startup -or $Verified)
}

function Save-CertificateSettings {
    param([Parameter(Mandatory)][string]$InputPath, [Microsoft.Win32.RegistryKey]$RegistryKey)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Choose a certificate folder first.' }
    $value = $InputPath.Trim()
    $ownsKey = $null -eq $RegistryKey
    try {
        if ($ownsKey) { $RegistryKey = Open-CertificateSettingsKey -Writable }
        $RegistryKey.SetValue('InputPath', $value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        if ($RegistryKey.GetValueKind('InputPath') -ne [Microsoft.Win32.RegistryValueKind]::ExpandString -or
            $RegistryKey.GetValue('InputPath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $value) {
            throw 'Could not verify the saved certificate folder in HKCU.'
        }
    } finally {
        if ($ownsKey -and $null -ne $RegistryKey) { $RegistryKey.Dispose() }
    }
}

function Get-CertificateLaunchArguments {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$DefaultInputPath = '%USERPROFILE%\Documents\CertificateBackups',
        [string]$InputPath,
        [switch]$Startup
    )
    $fullPath = [IO.Path]::GetFullPath($ScriptPath)
    if ($fullPath.Contains('"')) { throw 'The script path cannot contain quotation marks.' }
    $folder = $DefaultInputPath
    $parameter = '-DefaultInputPath'
    if ($PSBoundParameters.ContainsKey('InputPath')) { $folder = $InputPath; $parameter = '-InputPath' }
    if ([string]::IsNullOrWhiteSpace($folder) -or $folder.Contains('"') -or
        $folder.Contains("`r") -or $folder.Contains("`n")) {
        throw 'The default backup folder must not be empty or contain quotes/newlines.'
    }
    if ($folder.EndsWith('\')) { $folder += '.' }
    $startupArgument = if ($Startup) { ' -Startup' } else { '' }
    return '-NoProfile -STA -WindowStyle Hidden -File "{0}"{1} {2} "{3}"' -f $fullPath, $startupArgument, $parameter, $folder
}

function Get-CertificateStartupCommand {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$DefaultInputPath = '%USERPROFILE%\Documents\CertificateBackups'
    )
    $hostPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return '"{0}" {1}' -f $hostPath, (Get-CertificateLaunchArguments -ScriptPath $ScriptPath -DefaultInputPath $DefaultInputPath -Startup)
}

function Get-CertificateStartupEnabled {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try { return $null -ne $key -and $null -ne $key.GetValue('CertificateSignIn') }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Set-CertificateStartup {
    param(
        [bool]$Enabled,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$DefaultInputPath = '%USERPROFILE%\Documents\CertificateBackups'
    )
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try {
        if ($Enabled) {
            $key.SetValue('CertificateSignIn', (Get-CertificateStartupCommand -ScriptPath $ScriptPath -DefaultInputPath $DefaultInputPath),
                [Microsoft.Win32.RegistryValueKind]::String)
        } else { $key.DeleteValue('CertificateSignIn', $false) }
    } finally { $key.Dispose() }
}

Export-ModuleMember -Function Find-NewestCertificate, Assert-CertificatePrivateKey, Assert-CertificateBundle,
    Import-UserCertificate, Get-CertificateSettings, Save-CertificateSettings, Get-CertificateStartupCommand,
    Get-CertificateStartupEnabled, Set-CertificateStartup, Resolve-CertificateInputPath, Test-CertificateFormCloseAllowed
Export-ModuleMember -Function Get-CertificateFolderPresentation, Get-CertificateFileHash, Get-CertificateBackupManifest, Get-ManagedCertificateBackupPath,
    Get-CertificateFileInventory, Import-CertificateCollection, Get-CertificatePolicy, Get-CertificateLaunchArguments

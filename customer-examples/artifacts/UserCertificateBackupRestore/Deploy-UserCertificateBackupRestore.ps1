#Requires -Version 5.1
<#
.SYNOPSIS
Installs interactive user certificate restore and backup tools on an AVD host.
.DESCRIPTION
Runs silently during image creation or session-host customization. Installs
all-user startup and Start Menu shortcuts without accessing any user keys.
Managed folder policy changes only when the corresponding parameter is supplied.
User-selected folders are saved by the interactive tools in HKCU, never by this
administrator/SYSTEM installer. Administrative folder values remain authoritative.
.PARAMETER DeploymentType
Install (default) installs or updates the application. Uninstall removes its
runtime files and shortcuts, preserving user data and policies by default.
.PARAMETER RemovePolicySettings
Uninstall only. Remove the three application settings from local GPO and HKLM.
Use only when this deployment owns those settings; other managers may reapply them.
.PARAMETER RemovePolicyTemplates
Uninstall only. Remove matching bundled ADMX/ADML from local PolicyDefinitions.
.PARAMETER DefaultInputPath
Fallback used when no managed value, explicit path, or saved user folder exists.
Environment references are preserved for expansion in each user's session.
Use literal '%USERPROFILE%\...' strings, not "$env:USERPROFILE\...", which
PowerShell expands in the calling administrator/SYSTEM session before deployment.
No automatic conversion from PowerShell expressions to percent tokens occurs.
.PARAMETER InputPath
Optional shortcut folder override over saved HKCU preferences. Managed HKLM
registry values still take precedence. Omit this to allow remembered user folders.
.PARAMETER RestoreFolder
Optional authoritative RestoreFolder policy value, stored as REG_EXPAND_SZ.
.PARAMETER BackupFolder
Optional authoritative BackupFolder policy value, stored as REG_EXPAND_SZ.
.PARAMETER ExpiryWarningDays
Optional expiry warning window for both forms, from 1 to 365 days.
.PARAMETER ConfigureLocalGpo
Merge supplied settings into machine Registry.pol and install local templates.
Implies InstallPolicyTemplates; the separate switch is unnecessary.
Policy becomes effective at the next computer policy refresh; no gpupdate runs.
.PARAMETER InstallPolicyTemplates
Install the bundled ADMX/ADML into local PolicyDefinitions without configuring GPO.
Use independently when ConfigureLocalGpo is not requested.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [switch]$RemovePolicySettings,
    [switch]$RemovePolicyTemplates,
    [ValidateNotNullOrEmpty()]
    [string]$DefaultInputPath = '%USERPROFILE%\Documents\CertificateBackups',
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,
    [ValidateNotNullOrEmpty()]
    [string]$RestoreFolder,
    [ValidateNotNullOrEmpty()]
    [string]$BackupFolder,
    [ValidateRange(1, 365)]
    [int]$ExpiryWarningDays,
    [switch]$ConfigureLocalGpo,
    [switch]$InstallPolicyTemplates
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:_PRegEnc = [Text.Encoding]::Unicode
$script:_PolQueue = [Collections.Generic.List[hashtable]]::new()

# PReg encoding, queue merging, and CSE/version handling follow Configure-EdgePolicy.
function Read-PRegFile {
    param([string]$Path)
    $entries = [Collections.Generic.List[hashtable]]::new()
    if (-not [IO.File]::Exists($Path)) { return ,$entries }
    $raw = [IO.File]::ReadAllBytes($Path)
    $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new($raw, $false))
    try {
        if ($raw.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'PReg' -or
            $reader.ReadUInt32() -ne 1) { throw "RegistryPol: invalid header in '$Path'; existing policy was not discarded." }
        while ($reader.BaseStream.Position -lt $reader.BaseStream.Length) {
            if ($reader.ReadUInt16() -ne 0x5B) { throw "RegistryPol: invalid entry start in '$Path'." }
            $fields = @()
            foreach ($field in @('Key', 'Name')) {
                $start = [int]$reader.BaseStream.Position
                while ($reader.ReadUInt16() -ne 0) { }
                $length = [int]$reader.BaseStream.Position - $start - 2
                $fields += $script:_PRegEnc.GetString($raw, $start, $length)
                if ($reader.ReadUInt16() -ne 0x3B) { throw "RegistryPol: invalid $field separator in '$Path'." }
            }
            $type = $reader.ReadUInt32()
            if ($reader.ReadUInt16() -ne 0x3B) { throw "RegistryPol: invalid type separator in '$Path'." }
            $size = $reader.ReadUInt32()
            if ($reader.ReadUInt16() -ne 0x3B -or $size -gt $reader.BaseStream.Length - $reader.BaseStream.Position - 2) {
                throw "RegistryPol: invalid data size in '$Path'."
            }
            $data = $reader.ReadBytes([int]$size)
            if ($reader.ReadUInt16() -ne 0x5D) { throw "RegistryPol: invalid entry end in '$Path'." }
            $entries.Add(@{ Key = $fields[0]; Name = $fields[1]; Type = $type; Size = $size; Data = $data })
        }
        return ,$entries
    } finally { $reader.Dispose() }
}

function Write-PRegFile {
    param([string]$Path, [Collections.Generic.List[hashtable]]$Entries)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $zone = if ([IO.File]::Exists($Path) -and (Read-ZoneId $Path) -eq 4) { 4 } else { 3 }
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $temporary = "$Path.tmp"
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('PReg'))
        $writer.Write([uint32]1)
        foreach ($entry in $Entries) {
            $writer.Write([uint16]0x5B)
            $writer.Write($script:_PRegEnc.GetBytes($entry.Key)); $writer.Write([uint16]0); $writer.Write([uint16]0x3B)
            $writer.Write($script:_PRegEnc.GetBytes($entry.Name)); $writer.Write([uint16]0); $writer.Write([uint16]0x3B)
            $writer.Write([uint32]$entry.Type); $writer.Write([uint16]0x3B)
            $writer.Write([uint32]$entry.Size); $writer.Write([uint16]0x3B)
            if ($entry.Data.Length -gt 0) { $writer.Write([byte[]]$entry.Data) }
            $writer.Write([uint16]0x5D)
        }
        $writer.Flush()
        $bytes = $stream.ToArray()
        [IO.File]::WriteAllBytes($temporary, $bytes)
        Set-FileZone $temporary $zone
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($temporary)) -cne [Convert]::ToBase64String($bytes)) {
            throw "RegistryPol: staged write verification failed for '$Path'."
        }
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } finally {
        $writer.Dispose()
        $stream.Dispose()
        if ([IO.File]::Exists($temporary)) { Set-FileZone $temporary $zone }
        if ([IO.File]::Exists($Path)) { Set-FileZone $Path $zone }
    }
}

function Set-PRegEntry {
    param([Collections.Generic.List[hashtable]]$Entries, [string]$Key, [string]$Name, [uint32]$Type, [byte[]]$Data)
    foreach ($old in @($Entries | Where-Object {
        $_.Key -ieq $Key -and ($_.Name -ieq $Name -or $_.Name -ieq "**Del.$Name")
    })) {
        [void]$Entries.Remove($old)
    }
    $Entries.Add(@{ Key = $Key; Name = $Name; Type = $Type; Size = [uint32]$Data.Length; Data = $Data })
}

function ConvertTo-PRegDWord {
    param([uint32]$Value)
    return [BitConverter]::GetBytes($Value)
}

function ConvertTo-PRegSZ {
    param([string]$Value)
    return $script:_PRegEnc.GetBytes($Value + [char]0)
}

function Get-RelativePolicyKeyPath {
    param([string]$Path)
    foreach ($prefix in @('HKEY_LOCAL_MACHINE:\', 'HKEY_CURRENT_USER:\', 'HKEY_LOCAL_MACHINE:',
        'HKEY_CURRENT_USER:', 'HKLM:\', 'HKCU:\', 'HKLM:', 'HKCU:')) {
        if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($prefix.Length).TrimStart('\') }
    }
    return $Path
}

function Set-PolicyRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Computer', 'User')][string]$Scope,
        [Parameter(Mandatory)][string]$RegistryKeyPath,
        [Parameter(Mandatory)][string]$RegistryValue,
        [Parameter(Mandatory)][ValidateSet('DWORD', 'String', 'SZ', 'ExpandString', 'ExpandSZ')][string]$RegistryType,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RegistryData
    )
    $type = switch ($RegistryType.ToUpperInvariant()) {
        'DWORD' { 4 }
        'EXPANDSTRING' { 2 }
        'EXPANDSZ' { 2 }
        default { 1 }
    }
    $data = if ($type -eq 4) { [byte[]](ConvertTo-PRegDWord ([uint32]$RegistryData)) } else { [byte[]](ConvertTo-PRegSZ $RegistryData) }
    $script:_PolQueue.Add(@{
        Scope = $Scope; Key = (Get-RelativePolicyKeyPath $RegistryKeyPath); Name = $RegistryValue
        Type = [uint32]$type; Size = [uint32]$data.Length; Data = $data
    })
}

function Set-PRegIniValue {
    param([Collections.Generic.List[string]]$Lines, [string]$Name, [string]$Value)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -ieq '[General]') { $start = $i; break }
    }
    if ($start -eq -1) { $Lines.Add('[General]'); $start = $Lines.Count - 1 }
    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[') { $end = $i; break }
        if ($Lines[$i] -match ('^\s*' + [regex]::Escape($Name) + '\s*=')) { $Lines[$i] = "$Name=$Value"; return }
    }
    $Lines.Insert($end, "$Name=$Value")
}

function Remove-PolicyRegistryValue {
    param([string]$RegistryKeyPath, [string]$RegistryValue)
    $script:_PolQueue.Add(@{
        Scope = 'Computer'; Key = $RegistryKeyPath; Name = $RegistryValue; Remove = $true
    })
}

function Invoke-PolicyUpdate {
    [CmdletBinding()]
    param()
    if ($script:_PolQueue.Count -eq 0) { return }
    $base = Join-Path $env:SystemRoot 'System32\GroupPolicy'
    $gptPath = Join-Path $base 'gpt.ini'
    $text = if ([IO.File]::Exists($gptPath)) { [IO.File]::ReadAllText($gptPath, [Text.Encoding]::Default) } else { '' }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split '\r?\n')) { $lines.Add($line) }
    $general = @{}
    $inGeneral = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { $inGeneral = $line.Trim() -ieq '[General]'; continue }
        if ($inGeneral -and $line -match '^\s*([^=]+?)\s*=(.*)$') { $general[$matches[1]] = $matches[2].Trim() }
    }
    $version = [uint32]65537
    if ($general.ContainsKey('Version')) {
        if (-not [uint32]::TryParse($general.Version, [ref]$version)) { throw "RegistryPol: invalid gpt.ini version in '$gptPath'." }
    }
    $machineVersion = [uint32]($version -band 0xFFFF)
    $userVersion = [uint32](($version -shr 16) -band 0xFFFF)
    $regCse = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
    $pending = @()
    foreach ($scope in @(
        @{ Name = 'Computer'; Directory = 'Machine'; Extension = 'gPCMachineExtensionNames'; Editor = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}' },
        @{ Name = 'User'; Directory = 'User'; Extension = 'gPCUserExtensionNames'; Editor = '{D02B1F73-3407-48AE-BA88-E8213C6761F1}' }
    )) {
        $queue = @($script:_PolQueue | Where-Object { $_.Scope -eq $scope.Name })
        if ($queue.Count -eq 0) { continue }
        $path = Join-Path $base ($scope.Directory + '\Registry.pol')
        $entries = Read-PRegFile $path
        foreach ($item in $queue) {
            if ($item.ContainsKey('Remove') -and $item.Remove) {
                foreach ($old in @($entries | Where-Object {
                    $_.Key -ieq $item.Key -and ($_.Name -ieq $item.Name -or $_.Name -ieq "**Del.$($item.Name)")
                })) { [void]$entries.Remove($old) }
            } else {
                Set-PRegEntry $entries $item.Key $item.Name $item.Type $item.Data
            }
        }
        $pending += @{ Path = $path; Entries = $entries }
        $extension = if ($general.ContainsKey($scope.Extension)) { $general[$scope.Extension] } else { '' }
        if ($extension -notlike "*$regCse*") { $extension += "[$regCse$($scope.Editor)]" }
        Set-PRegIniValue $lines $scope.Extension $extension
        if ($scope.Name -eq 'Computer') { $machineVersion = ($machineVersion + 1) -band 0xFFFF }
        else { $userVersion = ($userVersion + 1) -band 0xFFFF }
    }
    Set-PRegIniValue $lines 'Version' ((([uint32]$userVersion -shl 16) -bor $machineVersion).ToString())
    foreach ($item in $pending) { Write-PRegFile $item.Path $item.Entries }
    $zone = if ([IO.File]::Exists($gptPath) -and (Read-ZoneId $gptPath) -eq 4) { 4 } else { 3 }
    $encoding = [Text.Encoding]::Default
    if ([IO.File]::Exists($gptPath)) {
        $existing = [IO.File]::ReadAllBytes($gptPath)
        if ($existing.Length -ge 2 -and $existing[0] -eq 0xFF -and $existing[1] -eq 0xFE) { $encoding = [Text.Encoding]::Unicode }
        elseif ($existing.Length -ge 2 -and $existing[0] -eq 0xFE -and $existing[1] -eq 0xFF) { $encoding = [Text.Encoding]::BigEndianUnicode }
        elseif ($existing.Length -ge 3 -and $existing[0] -eq 0xEF -and $existing[1] -eq 0xBB -and $existing[2] -eq 0xBF) { $encoding = [Text.Encoding]::UTF8 }
    }
    try { [IO.File]::WriteAllText($gptPath, ($lines -join "`r`n"), $encoding) }
    finally { if ([IO.File]::Exists($gptPath)) { Set-FileZone $gptPath $zone } }
    $script:_PolQueue.Clear()
}

function Copy-CertificatePolicyTemplates {
    param([string]$SourceDirectory, [string]$DestinationDirectory)
    [void][IO.Directory]::CreateDirectory((Join-Path $DestinationDirectory 'en-US'))
    foreach ($name in @('CertificateSignIn.admx', 'en-US\CertificateSignIn.adml')) {
        Copy-FileKeepingZone (Join-Path $SourceDirectory $name) (Join-Path $DestinationDirectory $name)
    }
}

function Remove-CertificateRegistrySettings {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Key)
    foreach ($name in @('RestoreFolder', 'BackupFolder', 'ExpiryWarningDays')) {
        $Key.DeleteValue($name, $false)
        if ($Key.GetValueNames() -contains $name) { throw "Could not remove the $name policy." }
    }
}

function Remove-CertificateApplicationFiles {
    param([string]$Destination, [string]$MenuFolder, [hashtable[]]$Links, [string[]]$FileNames)
    $directories = @(
        (Join-Path $Destination 'policy\en-US'), (Join-Path $Destination 'policy'),
        (Join-Path $Destination 'assets'), $Destination, $MenuFolder
    )
    foreach ($directory in $directories) {
        if ((Test-Path -LiteralPath $directory) -and
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Uninstall will not follow a redirected application directory: $directory"
        }
    }
    $files = @($Links | ForEach-Object { $_.Path }) + @($FileNames | ForEach-Object { Join-Path $Destination $_ })
    foreach ($path in $files) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
    foreach ($directory in $directories) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force | Select-Object -First 1).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
        }
    }
}

function Remove-CertificatePolicyTemplates {
    param([string]$SourceDirectory, [string]$DestinationDirectory)
    foreach ($directory in @($DestinationDirectory, (Join-Path $DestinationDirectory 'en-US'))) {
        if ((Test-Path -LiteralPath $directory) -and
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Template cleanup will not follow a redirected policy directory: $directory"
        }
    }
    $files = @()
    foreach ($name in @('CertificateSignIn.admx', 'en-US\CertificateSignIn.adml')) {
        $path = Join-Path $DestinationDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $source = Join-Path $SourceDirectory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($source)) -cne
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) {
            throw "Policy template differs from this package; remove it through its owner: $path"
        }
        $files += $path
    }
    foreach ($path in $files) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
}

function Remove-LegacyCertificateShortcuts {
    param([string]$Destination, [string[]]$MenuFolder, [hashtable[]]$Links, [string]$HostPath)
    foreach ($folder in $MenuFolder) {
        if ((Test-Path -LiteralPath $folder) -and
            ((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Shortcut migration will not follow a redirected legacy menu: $folder"
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($link in $Links) {
            if (-not (Test-Path -LiteralPath $link.Path -PathType Leaf)) { continue }
            $shortcut = $shell.CreateShortcut($link.Path)
            try {
                $scriptArgument = ' -File "' + (Join-Path $Destination $link.Script) + '"'
                $owned = ($shortcut.TargetPath -ieq $HostPath -and
                    $shortcut.Arguments.IndexOf($scriptArgument, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                    $shortcut.TargetPath -ieq (Join-Path $Destination 'CertificateSignIn.exe')
            } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
            if ($owned) { Remove-Item -LiteralPath $link.Path -Force -ErrorAction Stop }
            else { Write-Warning "Preserving an unrelated shortcut at the legacy location: $($link.Path)" }
        }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    foreach ($folder in $MenuFolder) {
        if ((Test-Path -LiteralPath $folder -PathType Container) -and
            @(Get-ChildItem -LiteralPath $folder -Force | Select-Object -First 1).Count -eq 0) {
            Remove-Item -LiteralPath $folder -Force -ErrorAction Stop
        }
    }
}

try {
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
        throw 'Run this artifact with 64-bit Windows PowerShell 5.1 on Windows.'
    }
    $runtime = Join-Path $PSScriptRoot 'scripts'
    $required = @('CertificateSignIn.ps1', 'CertificateSignIn.Core.psm1',
        'CertificateBackup.ps1', 'CertificateBackup.Core.psm1', 'Set-FileZone.ps1', 'assets\certificate-banner.png',
        'assets\certificate-backup-banner.png', 'assets\certificate-restore.ico', 'assets\certificate-backup.ico',
        'policy\CertificateSignIn.admx', 'policy\en-US\CertificateSignIn.adml')
    $destination = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'CertificateSignIn'
    $startupFolder = [Environment]::GetFolderPath('CommonStartup')
    $linkPath = Join-Path $startupFolder 'User Certificate Backup & Restore.lnk'
    $menuFolder = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'User Certificate Backup & Restore'
    $links = @(
        @{ Path = $linkPath; Script = 'CertificateSignIn.ps1'; Icon = 'certificate-restore.ico'; Startup = $true; Description = 'Restore backed-up user certificates at sign-in.' },
        @{ Path = (Join-Path $menuFolder 'Restore certificates.lnk'); Script = 'CertificateSignIn.ps1'; Icon = 'certificate-restore.ico'; Startup = $false; Description = 'Restore your backed-up software certificates.' },
        @{ Path = (Join-Path $menuFolder 'Back up certificates.lnk'); Script = 'CertificateBackup.ps1'; Icon = 'certificate-backup.ico'; Startup = $false; Description = 'Select and back up your software certificates after enrollment or renewal.' }
    )
    $hostPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $legacyMenuFolder = @(
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Certificate Sign-In'),
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Certificate Restore & Backup')
    )
    $legacyLinks = @(
        @{ Path = (Join-Path $startupFolder 'Certificate Sign-In.lnk'); Script = 'CertificateSignIn.ps1' },
        @{ Path = (Join-Path $startupFolder 'Certificate Restore & Backup.lnk'); Script = 'CertificateSignIn.ps1' }
        foreach ($folder in $legacyMenuFolder) {
            @{ Path = (Join-Path $folder 'Restore certificates.lnk'); Script = 'CertificateSignIn.ps1' }
            @{ Path = (Join-Path $folder 'Back up certificates.lnk'); Script = 'CertificateBackup.ps1' }
        }
    )
    if ($DeploymentType -eq 'Uninstall') {
        foreach ($name in @('DefaultInputPath', 'InputPath', 'RestoreFolder', 'BackupFolder', 'ExpiryWarningDays', 'ConfigureLocalGpo', 'InstallPolicyTemplates')) {
            if ($PSBoundParameters.ContainsKey($name)) { throw "$name is an installation-only parameter." }
        }
        $action = 'Uninstall application files and shortcuts; preserve certificates, backups and preferences'
        if ($RemovePolicySettings) { $action += '; remove application HKLM/local GPO settings' }
        if ($RemovePolicyTemplates) { $action += '; remove matching local policy templates' }
        if (-not $PSCmdlet.ShouldProcess($destination, $action)) { return }
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Run this deployment script in an elevated PowerShell window.'
        }
        if ($RemovePolicySettings) {
            . (Join-Path $runtime 'Set-FileZone.ps1')
            $policyKeyPath = 'Software\Policies\CertificateSignIn'
            $entries = Read-PRegFile (Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol')
            foreach ($name in @('RestoreFolder', 'BackupFolder', 'ExpiryWarningDays')) {
                if (@($entries | Where-Object {
                    $_.Key -ieq $policyKeyPath -and ($_.Name -ieq $name -or $_.Name -ieq "**Del.$name")
                }).Count -gt 0) { Remove-PolicyRegistryValue $policyKeyPath $name }
            }
            Invoke-PolicyUpdate
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
            $key = $null
            try {
                $key = $baseKey.OpenSubKey($policyKeyPath, $true)
                if ($null -ne $key) { Remove-CertificateRegistrySettings $key }
            } finally {
                if ($null -ne $key) { $key.Dispose() }
                $baseKey.Dispose()
            }
        }
        if ($RemovePolicyTemplates) {
            Remove-CertificatePolicyTemplates (Join-Path $runtime 'policy') (Join-Path $env:WINDIR 'PolicyDefinitions')
        }
        Remove-LegacyCertificateShortcuts $destination $legacyMenuFolder $legacyLinks $hostPath
        Remove-CertificateApplicationFiles -Destination $destination -MenuFolder $menuFolder -Links $links -FileNames $required
        Write-Host 'Uninstall complete. User certificates, keys, PFX backups, preferences and per-user Run entries were not changed. No gpupdate was run.'
        exit 0
    }
    if ($RemovePolicySettings -or $RemovePolicyTemplates) { throw 'Policy cleanup switches require DeploymentType Uninstall.' }
    foreach ($name in $required) {
        $path = Join-Path $runtime $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required packaged file is missing: $name" }
        if ([IO.Path]::GetExtension($path) -in '.ps1', '.psm1') {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0 -or [IO.File]::ReadAllText($path) -match '[^\x00-\x7E]') {
                throw "Packaged PowerShell must be valid and ASCII-only: $name"
            }
        }
    }
    Import-Module (Join-Path $runtime 'CertificateSignIn.Core.psm1') -ErrorAction Stop
    . (Join-Path $runtime 'Set-FileZone.ps1')
    $launchDefaults = @{ DefaultInputPath = $DefaultInputPath }
    if ($PSBoundParameters.ContainsKey('InputPath')) { $launchDefaults.InputPath = $InputPath }
    $folderArgument = $DefaultInputPath
    if ($PSBoundParameters.ContainsKey('InputPath')) { $folderArgument = $InputPath }
    if ($folderArgument.EndsWith('\')) {
        throw 'The input folder must not end in a backslash. For a drive root, use C:\. instead of a trailing backslash.'
    }
    [void](Get-CertificateLaunchArguments -ScriptPath (Join-Path $runtime 'CertificateSignIn.ps1') @launchDefaults)
    $managedValues = @{}
    foreach ($name in @('RestoreFolder', 'BackupFolder')) {
        if (-not $PSBoundParameters.ContainsKey($name)) { continue }
        $value = $PSBoundParameters[$name].Trim()
        if ([string]::IsNullOrWhiteSpace($value) -or $value.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
            $value -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$)|%[A-Za-z_][A-Za-z_0-9]*%(?:\\|$))' -or
            $value -match '^\\\\[?.]\\') {
            throw "$name must be an absolute drive/UNC path or a user-environment-rooted path."
        }
        $managedValues[$name] = @{ Data = $value; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString; PolicyType = 'ExpandString' }
    }
    if ($PSBoundParameters.ContainsKey('ExpiryWarningDays')) {
        $managedValues.ExpiryWarningDays = @{ Data = $ExpiryWarningDays; Kind = [Microsoft.Win32.RegistryValueKind]::DWord; PolicyType = 'DWORD' }
    }
    $action = if ($ConfigureLocalGpo) { 'Install certificate tools/templates and merge supplied settings into machine Registry.pol' }
        elseif ($InstallPolicyTemplates) { 'Install certificate tools/templates and apply supplied HKLM settings' }
        else { 'Install all-user certificate tools and apply explicitly supplied HKLM settings' }
    if (-not $PSCmdlet.ShouldProcess($destination, $action)) {
        return
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this deployment script in an elevated PowerShell window.'
    }
    Write-Host 'Installing User Certificate Backup & Restore. No user certificate, backup, or password is accessed during deployment.'
    $before = @()
    foreach ($directory in @($destination, $startupFolder, $menuFolder)) {
        if (Test-Path -LiteralPath $directory) {
            $before += Get-ChildItem -LiteralPath $directory -Recurse -File -Force | Select-Object FullName, Length, LastWriteTimeUtc
        }
    }
    $written = @($required | ForEach-Object { Join-Path $destination $_ }) + @($links | ForEach-Object { $_.Path })
    $shortcut = $null
    $shell = $null
    try {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        foreach ($name in $required) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName((Join-Path $destination $name)))
            Copy-FileKeepingZone (Join-Path $runtime $name) (Join-Path $destination $name)
        }
        $shell = New-Object -ComObject WScript.Shell
        [void][IO.Directory]::CreateDirectory($menuFolder)
        foreach ($link in $links) {
            $arguments = @{ ScriptPath = (Join-Path $destination $link.Script); Startup = $link.Startup }
            $shortcut = $shell.CreateShortcut($link.Path)
            try {
                $shortcut.TargetPath = $hostPath
                $shortcut.Arguments = Get-CertificateLaunchArguments @arguments @launchDefaults
                $shortcut.WorkingDirectory = $destination
                $shortcut.Description = $link.Description
                $shortcut.IconLocation = (Join-Path $destination ('assets\' + $link.Icon)) + ',0'
                $shortcut.Save()
            } finally {
                if ($null -ne $shortcut) {
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
                    $shortcut = $null
                }
            }
        }
    } finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        $after = @()
        foreach ($directory in @($destination, $startupFolder, $menuFolder)) {
            if (Test-Path -LiteralPath $directory) { $after += Get-ChildItem -LiteralPath $directory -Recurse -File -Force }
        }
        foreach ($file in $after) {
            $old = $before | Where-Object FullName -EQ $file.FullName | Select-Object -First 1
            if ($file.FullName -in $written -or -not $old -or $old.Length -ne $file.Length -or $old.LastWriteTimeUtc -ne $file.LastWriteTimeUtc) {
                Set-FileZone $file.FullName
            }
        }
    }
    Remove-LegacyCertificateShortcuts $destination $legacyMenuFolder $legacyLinks $hostPath
    if ($ConfigureLocalGpo -or $InstallPolicyTemplates) {
        Copy-CertificatePolicyTemplates -SourceDirectory (Join-Path $runtime 'policy') -DestinationDirectory (Join-Path $env:WINDIR 'PolicyDefinitions')
    }
    if ($ConfigureLocalGpo) {
        foreach ($name in $managedValues.Keys) {
            Set-PolicyRegistryValue -Scope Computer -RegistryKeyPath 'Software\Policies\CertificateSignIn' `
                -RegistryValue $name -RegistryType $managedValues[$name].PolicyType -RegistryData ([string]$managedValues[$name].Data)
        }
        Invoke-PolicyUpdate
        Write-Host 'Local GPO settings staged. No gpupdate was run; apply at the next computer policy refresh/startup.'
    } elseif ($managedValues.Count -gt 0) {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $null
        try {
            $key = $baseKey.CreateSubKey('Software\Policies\CertificateSignIn')
            foreach ($name in $managedValues.Keys) {
                $key.SetValue($name, $managedValues[$name].Data, $managedValues[$name].Kind)
                if ($key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $managedValues[$name].Data) {
                    throw "Could not verify the deployed $name policy."
                }
            }
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            $baseKey.Dispose()
        }
    }
    Write-Host 'Deployment complete. Forms run only in interactive user sessions; no enrollment hook or backup task was registered.'
    exit 0
} catch {
    Write-Error "User Certificate Backup & Restore deployment failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}

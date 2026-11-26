[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [string]$StorageSuffix,
    [Parameter(Mandatory = $true)]
    [string]$TimeZone,

    [Parameter(Mandatory = $false)]
    [string]$AmdVmSize = 'false',

    [Parameter(Mandatory = $false)]
    [string]$NvidiaVmSize = 'false',

    [Parameter(Mandatory = $false)]
    [string]$ConfigureFSLogix = 'false',

    [Parameter(Mandatory = $false)]
    [ValidateSet('ProfileContainer', 'CloudCacheProfileContainer', 'ProfileOfficeContainer', 'CloudCacheProfileOfficeContainer')]
    [string]$ContainerType = 'ProfileContainer',

    [Parameter(Mandatory = $false)]
    [string]$IdentitySolution = '',

    [Parameter(Mandatory = $false)]
    [string]$LocalNetAppServers = '[]',

    [Parameter(Mandatory = $false)]
    [string]$LocalProfileStorageAccountNames = '[]',

    [Parameter(Mandatory = $false)]
    [string]$LocalProfileStorageAccountKeys = '[]',

    [Parameter(Mandatory = $false)]
    [string]$LocalOfficeStorageAccountNames = '[]',

    [Parameter(Mandatory = $false)]
    [string]$LocalOfficeStorageAccountKeys = '[]',

    [Parameter(Mandatory = $false)]
    [string]$OSSGroups = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteNetAppServers = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteProfileStorageAccountNames = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteProfileStorageAccountKeys = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteOfficeStorageAccountNames = '[]',

    [Parameter(Mandatory = $false)]
    [string]$RemoteOfficeStorageAccountKeys = '[]',

    [Parameter(Mandatory = $false)]
    [string]$SizeInMBs = '30000',

    [Parameter(Mandatory = $false)]
    [string]$StorageService = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


$Script:Name = 'Initialize-SessionHost'
$Script:LogPath = Join-Path -Path $env:SystemRoot -ChildPath "Logs\$Script:Name.log"

#region Helper Functions

function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $DateTime = Get-Date -Format 'MM-dd-yyyy HH:mm:ss'
    $Content = "[$DateTime]`t$Category`t`t$Message" 
    Add-Content $Script:LogPath $content -ErrorAction Stop
}

Function ConvertFrom-JsonString {
    [CmdletBinding()]
    param (
        [string]$JsonString,
        [string]$Name,
        [switch]$SensitiveValues      
    )
    If ($JsonString -ne '[]' -and $null -ne $JsonString) {
        [array]$Array = $JsonString.replace('\', '') | ConvertFrom-Json
        If ($Array.Length -gt 0) {
            If ($SensitiveValues) { Write-Log -message "Array '$Name' has $($Array.Length) members" } Else { Write-Log -message "$($Name): '$($Array -join "', '")'" }
            Return $Array
        }
        Else {
            Return
        }            
    }
    Else {
        Return
    }    
}

function Assert-FSLogixAzureFilesAccounts {
    param (
        [array]$LocalProfileNames,
        [array]$RemoteProfileNames,
        [array]$LocalOfficeNames,
        [array]$RemoteOfficeNames,
        [array]$Groups,
        [bool]$OfficeEnabled,
        [bool]$UseStorageKeys,
        [array]$LocalProfileKeys,
        [array]$RemoteProfileKeys,
        [array]$LocalOfficeKeys,
        [array]$RemoteOfficeKeys
    )

    if ($LocalProfileNames.Count -eq 0) {
        throw 'FSLogix Azure Files requires at least one local Profile account.'
    }
    if ($RemoteProfileNames.Count -gt 0 -and $RemoteProfileNames.Count -ne $LocalProfileNames.Count) {
        throw 'Remote Profile accounts must match the local shard count.'
    }
    if ($Groups.Count -gt 0 -and $Groups.Count -ne $LocalProfileNames.Count) {
        throw 'Object-specific groups must match the local Profile shard count.'
    }
    if ($OfficeEnabled) {
        if ($LocalOfficeNames.Count -ne $LocalProfileNames.Count -or $RemoteOfficeNames.Count -ne $RemoteProfileNames.Count) {
            throw 'Office requires one distinct account per Profile account in the same local and remote shard order.'
        }
    }
    elseif ($LocalOfficeNames.Count -gt 0 -or $RemoteOfficeNames.Count -gt 0) {
        throw 'Office account arrays must be empty for Profile-only containers.'
    }
    $AllNames = @($LocalProfileNames) + @($RemoteProfileNames) + @($LocalOfficeNames) + @($RemoteOfficeNames)
    if (@($AllNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        @($AllNames | Sort-Object -Unique).Count -ne $AllNames.Count) {
        throw 'Profile and Office accounts must be nonempty, unique and disjoint across local and remote roles.'
    }
    if ($UseStorageKeys) {
        if ($LocalProfileNames.Count -ne 1 -or $RemoteProfileNames.Count -gt 1 -or $Groups.Count -gt 0) {
            throw 'Storage-key EntraId requires one account per role and location, without object-specific sharding.'
        }
        if ($LocalProfileKeys.Count -ne $LocalProfileNames.Count -or $RemoteProfileKeys.Count -ne $RemoteProfileNames.Count -or
            $LocalOfficeKeys.Count -ne $LocalOfficeNames.Count -or $RemoteOfficeKeys.Count -ne $RemoteOfficeNames.Count) {
            throw 'Storage-key EntraId requires a separate key for every Profile and Office account.'
        }
        $AllKeys = @($LocalProfileKeys) + @($RemoteProfileKeys) + @($LocalOfficeKeys) + @($RemoteOfficeKeys)
        if (@($AllKeys | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Storage-key EntraId account keys cannot be empty.'
        }
    }
}

function Set-StorageAccountCredential {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Password
    )

    if (-not ('FederalAVD.StorageCredential' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace FederalAVD
{
    public static class StorageCredential
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Credential
        {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredWrite(ref Credential credential, uint flags);

        public static void Write(string targetName, string userName, string password)
        {
            if (String.IsNullOrEmpty(targetName) || String.IsNullOrEmpty(userName) || String.IsNullOrEmpty(password))
                throw new ArgumentException("Credential target, user name and password must not be empty.");
            if (password.Length > 1280)
                throw new ArgumentException("Credential password exceeds the Windows credential size limit.");

            IntPtr passwordBuffer = Marshal.StringToCoTaskMemUni(password);
            try
            {
                Credential credential = new Credential();
                credential.Type = 2; // CRED_TYPE_DOMAIN_PASSWORD: used by SMB authentication.
                credential.TargetName = targetName;
                credential.UserName = userName;
                credential.CredentialBlobSize = (uint)(password.Length * 2);
                credential.CredentialBlob = passwordBuffer;
                credential.Persist = 2; // CRED_PERSIST_LOCAL_MACHINE: same identity, across logon sessions.

                if (!CredWrite(ref credential, 0))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "Writing the storage credential failed (Win32 error " + error + ").");
                }
            }
            finally
            {
                Marshal.ZeroFreeCoTaskMemUnicode(passwordBuffer);
            }
        }
    }
}
'@
    }

    [FederalAVD.StorageCredential]::Write($TargetName, $UserName, $Password)
}

function Set-FSLogixStorageCredential {
    param (
        [string]$AccountName,
        [string]$AccountKey,
        [string]$Suffix
    )
    Set-StorageAccountCredential -TargetName "$AccountName.file.$Suffix" -UserName "localhost\$AccountName" -Password $AccountKey
}

Function Convert-GroupToSID {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string]$DomainName,

        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )
    Begin {
        [string]$groupSID = ''
    }
    Process {
        Try {
            $groupSID = (New-Object System.Security.Principal.NTAccount("$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        Catch {
            Try {
                $groupSID = (New-Object System.Security.Principal.NTAccount($DomainName, "$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            Catch {
                Write-Error -Message "Failed to convert group name '$GroupName' to SID."
            }
        }
        Write-Output -InputObject $groupSID
    }
}

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$Name,
        [Parameter()]
        [string]$Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )
    If (!(Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    If ($RemoteValue) {
        $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
        If ($Value -ne $CurrentValue) {
            Write-Log -message "Registry update: $Name = $Value (was: $CurrentValue)"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
        }
    }
    Else {
        Write-Log -message "Registry create: $Name = $Value"
        New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
    }
}

Function Set-LocalMachinePolicyValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string[]]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [object]$Value,
        [Parameter(Mandatory = $false)]
        [ValidateSet('DWord', 'String')]
        [string]$Type = 'DWord',
        [Parameter(Mandatory = $false)]
        [string]$GroupPolicyRoot = "$env:SystemRoot\System32\GroupPolicy"
    )

    $Utf16 = [System.Text.Encoding]::Unicode
    $PolicyPath = Join-Path -Path $GroupPolicyRoot -ChildPath 'Machine\Registry.pol'
    $Entries = [System.Collections.Generic.List[hashtable]]::new()

    If (Test-Path -Path $PolicyPath) {
        $Raw = [System.IO.File]::ReadAllBytes($PolicyPath)
        If ($Raw.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($Raw, 0, 4) -ne 'PReg') {
            Throw "Invalid Registry.pol header: $PolicyPath"
        }
        $Position = 8
        While ($Position -lt $Raw.Length) {
            If ($Position + 1 -ge $Raw.Length) { Break }
            If ($Raw[$Position] -ne 0x5B -or $Raw[$Position + 1] -ne 0x00) {
                $Position++
                Continue
            }
            $Position += 2
            $Start = $Position
            While ($Position + 1 -lt $Raw.Length -and -not ($Raw[$Position] -eq 0 -and $Raw[$Position + 1] -eq 0)) { $Position += 2 }
            $EntryKey = $Utf16.GetString($Raw, $Start, $Position - $Start)
            $Position += 4
            $Start = $Position
            While ($Position + 1 -lt $Raw.Length -and -not ($Raw[$Position] -eq 0 -and $Raw[$Position + 1] -eq 0)) { $Position += 2 }
            $EntryName = $Utf16.GetString($Raw, $Start, $Position - $Start)
            $Position += 4
            $EntryType = [BitConverter]::ToUInt32($Raw, $Position)
            $Position += 6
            $EntrySize = [BitConverter]::ToUInt32($Raw, $Position)
            $Position += 6
            $EntryData = If ($EntrySize -gt 0) { [byte[]]$Raw[$Position..($Position + $EntrySize - 1)] } Else { [byte[]]@() }
            $Position += $EntrySize + 2
            $Entries.Add(@{ Key = $EntryKey; Name = $EntryName; Type = $EntryType; Data = $EntryData })
        }
    }

    $EntryType = If ($Type -eq 'DWord') { [uint32]4 } Else { [uint32]1 }
    $EntryData = If ($Type -eq 'DWord') {
        [BitConverter]::GetBytes([uint32]$Value)
    }
    Else {
        $Utf16.GetBytes("$Value`0")
    }
    ForEach ($ValueName in $Name) {
        @($Entries | Where-Object { $_.Key -ieq $Key -and $_.Name -ieq $ValueName }) | ForEach-Object { $Entries.Remove($_) | Out-Null }
        $Entries.Add(@{ Key = $Key; Name = $ValueName; Type = $EntryType; Data = $EntryData })
    }

    $Stream = [System.IO.MemoryStream]::new()
    $Writer = [System.IO.BinaryWriter]::new($Stream)
    Try {
        $Writer.Write([System.Text.Encoding]::ASCII.GetBytes('PReg'))
        $Writer.Write([uint32]1)
        ForEach ($Entry in $Entries) {
            $Writer.Write([byte[]](0x5B, 0x00))
            $Writer.Write($Utf16.GetBytes($Entry.Key))
            $Writer.Write([byte[]](0x00, 0x00, 0x3B, 0x00))
            $Writer.Write($Utf16.GetBytes($Entry.Name))
            $Writer.Write([byte[]](0x00, 0x00, 0x3B, 0x00))
            $Writer.Write([uint32]$Entry.Type)
            $Writer.Write([byte[]](0x3B, 0x00))
            $Writer.Write([uint32]$Entry.Data.Length)
            $Writer.Write([byte[]](0x3B, 0x00))
            If ($Entry.Data.Length -gt 0) { $Writer.Write([byte[]]$Entry.Data) }
            $Writer.Write([byte[]](0x5D, 0x00))
        }
        $Writer.Flush()
        $Bytes = $Stream.ToArray()
    }
    Finally {
        $Writer.Dispose()
        $Stream.Dispose()
    }

    $PolicyDirectory = Split-Path -Path $PolicyPath -Parent
    If (-not (Test-Path -Path $PolicyDirectory)) { New-Item -Path $PolicyDirectory -ItemType Directory -Force | Out-Null }
    $TemporaryPath = "$PolicyPath.tmp"
    [System.IO.File]::WriteAllBytes($TemporaryPath, $Bytes)
    If ((Get-Item -Path $TemporaryPath).Length -ne $Bytes.Length) {
        Remove-Item -Path $TemporaryPath -Force -ErrorAction SilentlyContinue
        Throw "Registry.pol verification failed: $TemporaryPath"
    }
    Move-Item -Path $TemporaryPath -Destination $PolicyPath -Force

    $GptPath = Join-Path -Path $GroupPolicyRoot -ChildPath 'gpt.ini'
    $ExistingGpt = If (Test-Path -Path $GptPath) { Get-Content -Path $GptPath -Raw } Else { '' }
    $MachineVersion = [uint16]1
    $UserVersion = [uint16]0
    If ($ExistingGpt -match 'Version\s*=\s*(\d+)') {
        $CurrentVersion = [uint32]$Matches[1]
        $MachineVersion = [uint16]($CurrentVersion -band 0xFFFF)
        $UserVersion = [uint16](($CurrentVersion -shr 16) -band 0xFFFF)
    }
    $MachineVersion++
    $CombinedVersion = ([uint32]$UserVersion -shl 16) -bor [uint32]$MachineVersion
    $RegistryCse = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'
    $MachineAdministrativeTemplates = '{D02B1F72-3407-48AE-BA88-E8213C6761F1}'
    $MachineExtensions = If ($ExistingGpt -match 'gPCMachineExtensionNames\s*=\s*(.+)') { $Matches[1].Trim() } Else { '' }
    If ($MachineExtensions -notlike "*$RegistryCse*") { $MachineExtensions += "[$RegistryCse$MachineAdministrativeTemplates]" }
    $UserExtensions = If ($ExistingGpt -match 'gPCUserExtensionNames\s*=\s*(.+)') { $Matches[1].Trim() } Else { '' }
    $GptContent = "[General]`r`n"
    If ($MachineExtensions) { $GptContent += "gPCMachineExtensionNames=$MachineExtensions`r`n" }
    If ($UserExtensions) { $GptContent += "gPCUserExtensionNames=$UserExtensions`r`n" }
    $GptContent += "Version=$CombinedVersion`r`n"
    [System.IO.File]::WriteAllText($GptPath, $GptContent, [System.Text.Encoding]::ASCII)
    Write-Log -Message "Local Group Policy update: $($Name.Count) $Type value(s) under $Key"
}

#endregion Helper Functions

#region FSLogix Redirections XML Templates

$redirectionsXMLStart = @'
<?xml version="1.0" encoding="UTF-8"?>
<FrxProfileFolderRedirection ExcludeCommonFolders="0">
<Excludes>
'@

$redirectionsXMLExcludesTeams = @'
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLog</Exclude>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\GPUCache</Exclude>
<Exclude Copy="0">AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState</Exclude>
'@

$redirectionsXMLExcludesAzCLI = @'
<Exclude Copy="0">.Azure</Exclude>
'@

$redirectionsXMLEnd = @'
</Excludes>
<Includes>
</Includes>
</FrxProfileFolderRedirection>
'@

#endregion FSLogix Redirections XML Templates

#region Main Script

try {
    Write-Log -Message '========================================='
    Write-Log -Message 'AVD Session Host Initialization Starting'
    Write-Log -Message '========================================='
    
    Write-Log -Message "TimeZone=$TimeZone | ConfigureFSLogix=$ConfigureFSLogix | AmdVmSize=$AmdVmSize | NvidiaVmSize=$NvidiaVmSize"
    [bool]$ConfigureFSLogixBool = [System.Convert]::ToBoolean($ConfigureFSLogix)
    
    #region Phase 1: Session Host Configuration
    
    Write-Log -Message ''
    Write-Log -Message '========================================='
    Write-Log -Message 'Phase 1: Session Host Configuration'
    Write-Log -Message '========================================='
    
    # Configure Time Zone
    Set-TimeZone -Id "$TimeZone"
    Write-Log -Message "Time Zone set to: $TimeZone"
    
    # Initialize registry settings array
    $RegSettings = New-Object System.Collections.ArrayList
    
    # Enable Time Zone Redirection
    Set-LocalMachinePolicyValue -Key 'Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableTimeZoneRedirection' -Value 1
    
    # Add GPU Settings if applicable
    if ($AmdVmSize -eq 'true' -or $NvidiaVmSize -eq 'true') {
        Write-Log -Message "Adding GPU Settings"
        Set-LocalMachinePolicyValue -Key 'Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'bEnumerateHWBeforeSW' -Value 1
        Set-LocalMachinePolicyValue -Key 'Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'AVC444ModePreferred' -Value 1
        Set-LocalMachinePolicyValue -Key 'Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'AVChardwareEncodePreferred' -Value 1
    }
    
    # Configure FSLogix if specified
    If ($ConfigureFSLogixBool) {
        Write-Log -Message ''
        Write-Log -Message 'Configuring FSLogix'
        Write-Log -Message "IdentitySolution: $IdentitySolution"
        
        $CloudCacheBool = $ContainerType -like '*CloudCache*'
        $ProfileShareName = 'profile-containers'
        $OfficeShareName = if ($ContainerType -like '*Office*') { 'office-containers' } else { $null }
        Write-Log -Message "ContainerType: $ContainerType"
        Write-Log -Message "CloudCache: $CloudCacheBool"
        
        Write-Log -message "ProfileShareName: $ProfileShareName"
        Write-Log -message "OfficeShareName: $OfficeShareName"
        Write-Log -message "StorageService: $StorageService"
        
        if ($SizeInMBs -ne '' -and $null -ne $SizeInMBs) {
            [int]$SizeInMBsInt = $SizeInMBs
            Write-Log -message "SizeInMBs: $SizeInMBsInt"
        }
        Else {
            [int]$SizeInMBsInt = 30000
            Write-Log -message "SizeInMBs not specified. Defaulting to: $SizeInMBsInt"
        }
        
        $AzCLIInstalled = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Azure CLI' } | Select-Object -First 1
        $TeamsInstalled = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' }
        
        # Create Array Lists for storage paths
        [System.Collections.ArrayList]$LocalProfileContainerPaths = @()
        [System.Collections.ArrayList]$LocalCloudCacheProfileContainerPaths = @()
        [System.Collections.ArrayList]$LocalOfficeContainerPaths = @()
        [System.Collections.ArrayList]$LocalCloudCacheOfficeContainerPaths = @()
        [System.Collections.ArrayList]$RemoteProfileContainerPaths = @()
        [System.Collections.ArrayList]$RemoteCloudCacheProfileContainerPaths = @()
        [System.Collections.ArrayList]$RemoteOfficeContainerPaths = @()
        [System.Collections.ArrayList]$RemoteCloudCacheOfficeContainerPaths = @()
        
        # Process storage accounts based on service type
        switch ($StorageService) {
            'AzureFiles' {
                Write-Log -message "Gathering Azure Files Storage Account Parameters"
                [array]$OSSGroupsArray = @(ConvertFrom-JsonString -JsonString $OSSGroups -Name 'OSSGroups')
                [array]$LocalProfileStorageAccountNamesArray = @(ConvertFrom-JsonString -JsonString $LocalProfileStorageAccountNames -Name 'LocalProfileStorageAccountNames')
                [array]$RemoteProfileStorageAccountNamesArray = @(ConvertFrom-JsonString -JsonString $RemoteProfileStorageAccountNames -Name 'RemoteProfileStorageAccountNames')
                [array]$LocalOfficeStorageAccountNamesArray = @(ConvertFrom-JsonString -JsonString $LocalOfficeStorageAccountNames -Name 'LocalOfficeStorageAccountNames')
                [array]$RemoteOfficeStorageAccountNamesArray = @(ConvertFrom-JsonString -JsonString $RemoteOfficeStorageAccountNames -Name 'RemoteOfficeStorageAccountNames')
                [array]$LocalProfileStorageAccountKeysArray = @(ConvertFrom-JsonString -JsonString $LocalProfileStorageAccountKeys -Name 'LocalProfileStorageAccountKeys' -SensitiveValues)
                [array]$RemoteProfileStorageAccountKeysArray = @(ConvertFrom-JsonString -JsonString $RemoteProfileStorageAccountKeys -Name 'RemoteProfileStorageAccountKeys' -SensitiveValues)
                [array]$LocalOfficeStorageAccountKeysArray = @(ConvertFrom-JsonString -JsonString $LocalOfficeStorageAccountKeys -Name 'LocalOfficeStorageAccountKeys' -SensitiveValues)
                [array]$RemoteOfficeStorageAccountKeysArray = @(ConvertFrom-JsonString -JsonString $RemoteOfficeStorageAccountKeys -Name 'RemoteOfficeStorageAccountKeys' -SensitiveValues)
                $AccountValidation = @{
                    LocalProfileNames = $LocalProfileStorageAccountNamesArray
                    RemoteProfileNames = $RemoteProfileStorageAccountNamesArray
                    LocalOfficeNames = $LocalOfficeStorageAccountNamesArray
                    RemoteOfficeNames = $RemoteOfficeStorageAccountNamesArray
                    Groups = $OSSGroupsArray
                    OfficeEnabled = [bool]$OfficeShareName
                    UseStorageKeys = $IdentitySolution -eq 'EntraId'
                    LocalProfileKeys = $LocalProfileStorageAccountKeysArray
                    RemoteProfileKeys = $RemoteProfileStorageAccountKeysArray
                    LocalOfficeKeys = $LocalOfficeStorageAccountKeysArray
                    RemoteOfficeKeys = $RemoteOfficeStorageAccountKeysArray
                }
                Assert-FSLogixAzureFilesAccounts @AccountValidation
                if ($IdentitySolution -eq 'EntraId') {
                    # Managed Run Command executes as SYSTEM, the account used for storage-key SMB credentials.
                    Set-FSLogixStorageCredential -AccountName $LocalProfileStorageAccountNamesArray[0] -AccountKey $LocalProfileStorageAccountKeysArray[0] -Suffix $StorageSuffix
                    if ($OfficeShareName) {
                        Set-FSLogixStorageCredential -AccountName $LocalOfficeStorageAccountNamesArray[0] -AccountKey $LocalOfficeStorageAccountKeysArray[0] -Suffix $StorageSuffix
                    }
                    if ($RemoteProfileStorageAccountNamesArray.Count -gt 0) {
                        Set-FSLogixStorageCredential -AccountName $RemoteProfileStorageAccountNamesArray[0] -AccountKey $RemoteProfileStorageAccountKeysArray[0] -Suffix $StorageSuffix
                        if ($OfficeShareName) {
                            Set-FSLogixStorageCredential -AccountName $RemoteOfficeStorageAccountNamesArray[0] -AccountKey $RemoteOfficeStorageAccountKeysArray[0] -Suffix $StorageSuffix
                        }
                    }
                }
                
                # Process Local Storage Accounts
                Write-Log -message "Processing Local Storage Accounts"
                For ($i = 0; $i -lt $LocalProfileStorageAccountNamesArray.Count; $i++) {
                    $SAFQDN = "$($LocalProfileStorageAccountNamesArray[$i]).file.$StorageSuffix"
                    Write-Log -message "Local storage [$i]: $SAFQDN"
                    
                    If ($OfficeShareName) {
                        $OfficeSAFQDN = "$($LocalOfficeStorageAccountNamesArray[$i]).file.$StorageSuffix"
                        $LocalOfficeContainerPaths.Add("\\$OfficeSAFQDN\$OfficeShareName") | Out-Null
                        $LocalCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($OfficeSAFQDN)\$($OfficeShareName)") | Out-Null
                    }
                    $LocalProfileContainerPaths.Add("\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                    $LocalCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                }
                
                # Process Remote Storage Accounts
                If ($RemoteProfileStorageAccountNamesArray.Count -gt 0) {
                    Write-Log -message "Processing Remote Storage Accounts"
                    For ($i = 0; $i -lt $RemoteProfileStorageAccountNamesArray.Count; $i++) {
                        $SAFQDN = "$($RemoteProfileStorageAccountNamesArray[$i]).file.$StorageSuffix"
                        Write-Log -message "Remote storage [$i]: $SAFQDN"
                        
                        If ($OfficeShareName) {
                            $OfficeSAFQDN = "$($RemoteOfficeStorageAccountNamesArray[$i]).file.$StorageSuffix"
                            $RemoteOfficeContainerPaths.Add("\\$($OfficeSAFQDN)\$($OfficeShareName)") | Out-Null
                            $RemoteCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($OfficeSAFQDN)\$($OfficeShareName)") | Out-Null
                        }
                        $RemoteProfileContainerPaths.Add("\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                        $RemoteCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)") | Out-Null
                    }
                }
            }
            'AzureNetAppFiles' {
                Write-Log -message "Gathering Azure NetApp Files Storage Account Parameters"
                [array]$LocalNetAppServersArray = ConvertFrom-JsonString -JsonString $LocalNetAppServers -Name 'LocalNetAppServers'
                [array]$RemoteNetAppServersArray = ConvertFrom-JsonString -JsonString $RemoteNetAppServers -Name 'RemoteNetAppServers'
                
                Write-Log -message "Local NetApp: $($LocalNetAppServersArray[0])"
                $LocalProfileContainerPaths.Add("\\$($LocalNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                $LocalCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($LocalNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                
                If ($LocalNetAppServersArray.Length -gt 1 -and $OfficeShareName) {            
                    $LocalOfficeContainerPaths.Add("\\$($LocalNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                    $LocalCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($LocalNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                }
                
                If ($RemoteNetAppServersArray.Count -gt 0) {
                    Write-Log -message "Remote NetApp: $($RemoteNetAppServersArray[0])"
                    $RemoteProfileContainerPaths.Add("\\$($RemoteNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                    $RemoteCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($RemoteNetAppServersArray[0])\$($ProfileShareName)") | Out-Null
                    
                    If ($RemoteNetAppServersArray.Length -gt 1 -and $OfficeShareName) {
                        $RemoteOfficeContainerPaths.Add("\\$($RemoteNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                        $RemoteCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($RemoteNetAppServersArray[1])\$($OfficeShareName)") | Out-Null
                    }        
                }
            }
        }
        
        # Add Common FSLogix Registry Settings
        # ADMX Machine policy "Access Network as Computer Object" (v2105): DWORD 1 attaches as computer.
        # Storage-key access exposes all containers to the host; identity-based configurations remain unchanged.
        # https://learn.microsoft.com/fslogix/reference-configuration-settings#accessnetworkascomputerobject
        if ($IdentitySolution -eq 'EntraId' -and $LocalProfileStorageAccountKeysArray.Count -gt 0) {
            $RegSettings.Add([PSCustomObject]@{ Name = 'AccessNetworkAsComputerObject'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        }
        if ($IdentitySolution -eq 'EntraId' -and $LocalOfficeStorageAccountKeysArray.Count -gt 0) {
            $RegSettings.Add([PSCustomObject]@{ Name = 'AccessNetworkAsComputerObject'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
        }
        $RegSettings.Add([PSCustomObject]@{ Name = 'CleanupInvalidSessions'; Path = 'HKLM:\SOFTWARE\FSLogix\Apps'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'Enabled'; Path = 'HKLM:\SOFTWARE\Fslogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'DeleteLocalProfileWhenVHDShouldApply'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'FlipFlopProfileDirectoryName'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithFailure'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithTempProfile'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachIntervalSeconds'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 15 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachRetryCount'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 3 })
        $RegSettings.Add([PSCustomObject]@{ Name = 'SizeInMBs'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = $SizeInMBsInt })
        $RegSettings.Add([PSCustomObject]@{ Name = 'VolumeType'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'String'; Value = 'VHDX' })
        
        if ($CloudCacheBool -eq $True) {
            $RegSettings.Add([PSCustomObject]@{ Name = 'ClearCacheOnLogoff'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
        }
        
        # Office Container Settings
        If ($LocalOfficeContainerPaths.Count -gt 0) {
            $RegSettings.Add([PSCustomObject]@{ Name = 'Enabled'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })   
            $RegSettings.Add([PSCustomObject]@{ Name = 'FlipFlopProfileDirectoryName'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'LockedRetryCount'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 3 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'LockedRetryInterval'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 15 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithFailure'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithTempProfile'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })    
            $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachIntervalSeconds'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 15 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachRetryCount'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 3 })
            $RegSettings.Add([PSCustomObject]@{ Name = 'SizeInMBs'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = $SizeInMBsInt })
            $RegSettings.Add([PSCustomObject]@{ Name = 'VolumeType'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'String'; Value = 'VHDX' })
            
            If ($CloudCacheBool -eq $True) {
                $RegSettings.Add([PSCustomObject]@{ Name = 'ClearCacheOnLogoff'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
            }   
        }
        
        # Object Specific Settings or Standard VHDLocations/CCDLocations
        If ($OSSGroupsArray.Count -gt 0) {
            Write-Log -message "Adding Object Specific Settings"
            $DomainName = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty Domain
            Write-Log -message "DomainName: $DomainName"
            
            For ($i = 0; $i -lt $OSSGroupsArray.Count; $i++) {
                Write-Log -message "Getting SID for $($OSSGroupsArray[$i])"        
                $OSSGroupSID = Convert-GroupToSID -DomainName $DomainName -GroupName $OSSGroupsArray[$i]
                [string]$LocalProfileContainerPath = $LocalProfileContainerPaths[$i]
                [string]$LocalCloudCacheProfileContainerPath = $LocalCloudCacheProfileContainerPaths[$i]

                If ($RemoteProfileContainerPaths.Count -gt 0) {
                    [string]$RemoteProfileContainerPath = $RemoteProfileContainerPaths[$i]
                    [string]$RemoteCloudCacheProfileContainerPath = $RemoteCloudCacheProfileContainerPaths[$i]
                    [array]$ProfileContainerPathsForGroup = @($LocalProfileContainerPath, $RemoteProfileContainerPath)
                    [array]$CloudCacheProfileContainerPathsForGroup = @($LocalCloudCacheProfileContainerPath, $RemoteCloudCacheProfileContainerPath)
                }
                Else {
                    [array]$ProfileContainerPathsForGroup = @($LocalProfileContainerPath)
                    [array]$CloudCacheProfileContainerPathsForGroup = @($LocalCloudCacheProfileContainerPath)
                }

                If ($CloudCacheBool -eq $True) {
                    Write-Log -message "Adding Cloud Cache Profile Container Settings: $OSSGroupSID : '$($CloudCacheProfileContainerPathsForGroup -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = "HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $CloudCacheProfileContainerPathsForGroup })
                }
                Else {
                    Write-Log -message "Adding Profile Container Settings: $OSSGroupSID : '$($ProfileContainerPathsForGroup -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = "HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $ProfileContainerPathsForGroup })
                }   

                If ($LocalOfficeContainerPaths.Count -gt 0) {
                    [string]$LocalOfficeContainerPath = $LocalOfficeContainerPaths[$i]
                    [string]$LocalCloudCacheOfficeContainerPath = $LocalCloudCacheOfficeContainerPaths[$i]
                    
                    If ($RemoteOfficeContainerPaths.Count -gt 0) {
                        [string]$RemoteOfficeContainerPath = $RemoteOfficeContainerPaths[$i]
                        [string]$RemoteCloudCacheOfficeContainerPath = $RemoteCloudCacheOfficeContainerPaths[$i]
                        [array]$OfficeContainerPathsForGroup = @($LocalOfficeContainerPath, $RemoteOfficeContainerPath)
                        [array]$CloudCacheOfficeContainerPathsForGroup = @($LocalCloudCacheOfficeContainerPath, $RemoteCloudCacheOfficeContainerPath)
                    }
                    Else {
                        [array]$OfficeContainerPathsForGroup = @($LocalOfficeContainerPath)
                        [array]$CloudCacheOfficeContainerPathsForGroup = @($LocalCloudCacheOfficeContainerPath)
                    }
                    
                    If ($CloudCacheBool -eq $True) {
                        Write-Log -message "Adding Cloud Cache Office Container Settings: $OSSGroupSID : '$($CloudCacheOfficeContainerPathsForGroup -join "', '")'"
                        $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = "HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $CloudCacheOfficeContainerPathsForGroup })
                    }
                    Else {
                        Write-Log -message "Adding Office Container Settings: $OSSGroupSID : '$($OfficeContainerPathsForGroup -join "', '")'"
                        $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = "HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $OfficeContainerPathsForGroup })
                    }
                }  
            }          
        }
        Else {
            # No OSS Groups, use standard VHDLocations/CCDLocations
            If ($RemoteProfileContainerPaths.Count -gt 0) {
                $ProfileContainerPaths = $LocalProfileContainerPaths + $RemoteProfileContainerPaths
                $CloudCacheProfileContainerPaths = $LocalCloudCacheProfileContainerPaths + $RemoteCloudCacheProfileContainerPaths
            }
            Else {
                $ProfileContainerPaths = $LocalProfileContainerPaths
                $CloudCacheProfileContainerPaths = $LocalCloudCacheProfileContainerPaths
            }
            
            If ($CloudCacheBool -eq $True) {
                Write-Log -message "Adding Cloud Cache Profile Container Settings: '$($CloudCacheProfileContainerPaths -join "', '")'"   
                $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'MultiString'; Value = $CloudCacheProfileContainerPaths })             
            }
            Else {
                Write-Log -message "Adding Profile Container Settings: '$($ProfileContainerPaths -join "', '")'"
                $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'MultiString'; Value = $ProfileContainerPaths })
            }
            
            If ($LocalOfficeContainerPaths.Count -gt 0) {
                If ($RemoteOfficeContainerPaths.Count -gt 0) {
                    $OfficeContainerPaths = $LocalOfficeContainerPaths + $RemoteOfficeContainerPaths
                    $CloudCacheOfficeContainerPaths = $LocalCloudCacheOfficeContainerPaths + $RemoteCloudCacheOfficeContainerPaths
                }
                Else {
                    $OfficeContainerPaths = $LocalOfficeContainerPaths
                    $CloudCacheOfficeContainerPaths = $LocalCloudCacheOfficeContainerPaths
                }
                
                If ($CloudCacheBool -eq $True) {
                    Write-Log -message "Adding Cloud Cache Office Container Settings: '$($CloudCacheOfficeContainerPaths -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'MultiString'; Value = $CloudCacheOfficeContainerPaths })
                }
                Else {
                    Write-Log -message "Adding Office Container Settings: '$($OfficeContainerPaths -join "', '")'"
                    $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'MultiString'; Value = $OfficeContainerPaths })
                }
            }    
        }
        
        # FSLogix Redirections for Teams and Az CLI
        If ($TeamsInstalled -or $AzCLIInstalled) {
            $customRedirFolder = "$env:ProgramData\FSLogix_CustomRedirections"
            Write-Log -message "Creating custom redirections.xml file in $customRedirFolder"
            If (-not (Test-Path $customRedirFolder )) {
                New-Item -Path $customRedirFolder -ItemType Directory -Force | Out-Null
            }
            $customRedirFilePath = "$customRedirFolder\redirections.xml"
            $redirectionsXMLContent = $redirectionsXMLStart
            if ($AzCLIInstalled) {
                $redirectionsXMLContent = $redirectionsXMLContent + "`n" + $redirectionsXMLExcludesAzCLI
            }
            if ($TeamsInstalled) {
                $redirectionsXMLContent = $redirectionsXMLContent + "`n" + $redirectionsXMLExcludesTeams
            }
            $redirectionsXMLContent = $redirectionsXMLContent + "`n" + $redirectionsXMLEnd
            $redirectionsXMLContent | Out-File -FilePath $customRedirFilePath -Encoding unicode
            
            $RegSettings.Add([PSCustomObject]@{ Name = 'RedirXMLSourceFolder'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'String'; Value = $customRedirFolder })
        }
        
        # Entra Kerberos Cloud Kerberos Ticket Retrieval
        If ($IdentitySolution -match 'EntraKerberos') {
            Write-Log -message "Adding Entra Kerberos Cloud Kerberos Ticket Retrieval Local Group Policy"
            Set-LocalMachinePolicyValue -Key 'Software\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters' -Name 'CloudKerberosTicketRetrievalEnabled' -Value 1
            Write-Log -message "Adding Entra Kerberos Load Cred Key From Profile Setting"
            $RegSettings.Add([PSCustomObject]@{ Name = 'LoadCredKeyFromProfile'; Path = 'HKLM:\Software\Policies\Microsoft\AzureADAccount'; PropertyType = 'DWord'; Value = 1 })
        }

        # Microsoft Defender Antivirus Local Group Policy exclusions for FSLogix
        $LocalPathExclusions = @(
            "$env:ProgramData\FSLogix",
            "$env:ProgramFiles\FSLogix\Apps",
            "$env:SystemDrive\Users\*\AppData\Local\FSLogix",
            "$env:SystemRoot\Temp\*\*.vhdx",
            "$env:SystemDrive\Users\*\AppData\Local\Temp\*\*.vhdx"
        )
        
        # Build UNC path exclusions for containers and their companion files.
        $UncPathExclusions = @()
        $ContainerPaths = @($LocalProfileContainerPaths) + @($LocalOfficeContainerPaths) + @($RemoteProfileContainerPaths) + @($RemoteOfficeContainerPaths)
        $ContainerPatterns = '*.vhdx', '*.vhdx.lock', '*.vhdx.meta', '*.vhdx.metadata'
        ForEach ($ContainerPath in ($ContainerPaths | Where-Object { $_ } | Select-Object -Unique)) {
            $UncPathExclusions += $ContainerPatterns | ForEach-Object { "$ContainerPath\*\$_" }
        }

        [string[]]$PathExclusions = @($LocalPathExclusions + $UncPathExclusions | Select-Object -Unique)

        $ProcessExclusions = @(
            "$env:ProgramFiles\FSLogix\Apps\frxsvc.exe",
            "$env:ProgramFiles\FSLogix\Apps\frxccds.exe"
        )

        Try {
            $DefenderExclusionsKey = 'Software\Policies\Microsoft\Windows Defender\Exclusions'
            Set-LocalMachinePolicyValue -Key $DefenderExclusionsKey -Name 'Exclusions_Paths' -Value 1
            Set-LocalMachinePolicyValue -Key $DefenderExclusionsKey -Name 'Exclusions_Processes' -Value 1
            Set-LocalMachinePolicyValue -Key "$DefenderExclusionsKey\Paths" -Name $PathExclusions -Value '' -Type String
            Set-LocalMachinePolicyValue -Key "$DefenderExclusionsKey\Processes" -Name $ProcessExclusions -Value '' -Type String
            Write-Log -Message "Configured $($PathExclusions.Count) Defender path exclusions and $($ProcessExclusions.Count) process exclusions in Local Group Policy"
        }
        Catch {
            Write-Log -Category Warning -Message "Failed to configure Defender exclusions in Local Group Policy: $_"
        }

        # Add local administrator to FSLogix exclude lists
        $LocalAdministrator = (Get-LocalUser | Where-Object { $_.SID -like '*-500' }).Name
        $LocalGroups = 'FSLogix Profile Exclude List', 'FSLogix ODFC Exclude List'
        ForEach ($Group in $LocalGroups) {
            If (-not (Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$LocalAdministrator" })) {
                Write-Log -message "Adding $LocalAdministrator to $Group"
                Add-LocalGroupMember -Group $Group -Member $LocalAdministrator -ErrorAction SilentlyContinue
            }
        }
    }

    Try {
        $GroupPolicyUpdate = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/target:computer /force /wait:60' -Wait -PassThru -NoNewWindow
        If ($GroupPolicyUpdate.ExitCode -ne 0) {
            Throw "gpupdate.exe exited with code $($GroupPolicyUpdate.ExitCode)"
        }
        Write-Log -Message "Computer Group Policy refreshed successfully"
    }
    Catch {
        Write-Log -Category Warning -Message "Failed to refresh computer Group Policy: $_"
    }
    
    # Apply all registry settings
    ForEach ($Setting in $RegSettings) {
        Set-RegistryValue -Name $Setting.Name -Path $Setting.Path -PropertyType $Setting.PropertyType -Value $Setting.Value
    }
    
    # Resize OS Disk
    Write-Log -Message "Resizing OS Disk"
    try {
        $DriveLetter = $env:SystemDrive.TrimEnd(':')
        Update-HostStorageCache -ErrorAction SilentlyContinue
        $Part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $CurrentSizeGB = [math]::Round($Part.Size / 1GB, 2)
        Write-Log -Message "Current partition size: $CurrentSizeGB GB (drive: $DriveLetter)"

        # Use diskpart to extend - bypasses VDS entirely, no timing race on first boot.
        $diskpartScript = "select disk $($Part.DiskNumber)`r`nselect partition $($Part.PartitionNumber)`r`nextend"
        $scriptPath = Join-Path $env:TEMP 'diskpart_extend.txt'
        [System.IO.File]::WriteAllText($scriptPath, $diskpartScript, [System.Text.Encoding]::ASCII)
        $diskpartOutput = & diskpart /s $scriptPath 2>&1
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
        Write-Log -Message "Diskpart result: $($diskpartOutput -join ' | ')"

        $PartAfter = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($PartAfter -and $PartAfter.Size -gt $Part.Size) {
            $NewSizeGB = [math]::Round($PartAfter.Size / 1GB, 2)
            Write-Log -Message "OS Disk resized successfully: $CurrentSizeGB GB -> $NewSizeGB GB"
        } else {
            Write-Log -Message "OS Disk is already at maximum size. No resize needed."
        }
    }
    catch {
        Write-Log -Message "Failed to resize OS Disk: $($_.Exception.Message)" -Category 'Warning'
        Write-Log -Message "Continuing with deployment..."
    }
    
    Write-Log -Message "Phase 1: Session Host Configuration Complete"
    
    #endregion Phase 1: Session Host Configuration
    
    Write-Log -Message ''
    Write-Log -Message '========================================='
    Write-Log -Message 'Session Host Initialization Complete'
    Write-Log -Message '========================================='
    Write-Log -Message "Log file location: $Script:LogPath"    
    exit 0
}
catch {
    Write-Log -Category Error -Message "Initialization failed: $($_.Exception.Message)"
    Write-Log -Category Error -Message "Stack Trace: $($_.ScriptStackTrace)"
    Write-Log -Message "Log file location: $Script:LogPath"    
    exit 1
}

#endregion Main Script

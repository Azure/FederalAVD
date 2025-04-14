[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$AmdVmSize,
    [string]$NvidiaVmSize,
    [string]$DisableUpdates,
    [string]$ConfigureFSLogix,
    [string]$CloudCache = 'false',
    [string]$LocalNetAppServers,
    [string]$LocalStorageAccountNames,
    [string]$LocalStorageAccountKeys,
    [string]$OSSGroups,
    [string]$RemoteNetAppServers,
    [string]$RemoteStorageAccountNames,
    [string]$RemoteStorageAccountKeys,
    [string]$Shares,
    [string]$StorageAccountDNSSuffix,
    [string]$StorageService
)


#region Functions

function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
    )

    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

function Write-Log {
    Param (
        [Parameter(Mandatory=$false, Position=0)]
        [ValidateSet("Info","Warning","Error")]
        $Category = 'Info',
        [Parameter(Mandatory=$true, Position=1)]
        $Message
    )

    $Date = get-date
    $Content = "[$Date]`t$Category`t`t$Message`n" 
    Add-Content $Script:Log $content -ErrorAction Stop
    If ($Verbose) {
        Write-Verbose $Content
    } Else {
        Switch ($Category) {
            'Info' {Write-Host $content}
            'Error' {Write-Error $Content}
            'Warning' {Write-Warning $Content}
        }
    }
}

Function ConvertFrom-JsonString {
    [CmdletBinding()]
    param (
        [string]$JsonString,
        [string]$Name,
        [switch]$SensitiveValues      
    )
    If ($JsonString -ne '[]' -and $JsonString -ne $null) {
        [array]$Array = $JsonString.replace('\', '') | ConvertFrom-Json
        If ($Array.Length -gt 0) {
            If ($SensitiveValues) {Write-Log -message "Array '$Name' has $($Array.Length) members"} Else {Write-Log -message "$($Name): '$($Array -join "', '")'"}
            Return $Array
        } Else {
            Return $null
        }            
    } Else {
        Return $null
    }    
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
                $groupSID = (New-Object System.Security.Principal.NTAccount($DomainName,"$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            Catch {
                Write-Error -Message "Failed to convert group name '$GroupName' to SID."
            }
        }
        Write-Output -InputObject $groupSID
    }
}

Function Get-InstalledApplication {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNullorEmpty()]
        [string[]]$Name,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullorEmpty()]
        [string]$ProductCode
    )

    Begin {
        [string[]]$regKeyApplications = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    }
    Process { 
        ## Enumerate the installed applications from the registry for applications that have the "DisplayName" property
        [psobject[]]$regKeyApplication = @()
        ForEach ($regKey in $regKeyApplications) {
            If (Test-Path -LiteralPath $regKey -ErrorAction 'SilentlyContinue' -ErrorVariable '+ErrorUninstallKeyPath') {
                [psobject[]]$UninstallKeyApps = Get-ChildItem -LiteralPath $regKey -ErrorAction 'SilentlyContinue' -ErrorVariable '+ErrorUninstallKeyPath'
                ForEach ($UninstallKeyApp in $UninstallKeyApps) {
                    Try {
                        [psobject]$regKeyApplicationProps = Get-ItemProperty -LiteralPath $UninstallKeyApp.PSPath -ErrorAction 'Stop'
                        If ($regKeyApplicationProps.DisplayName) { [psobject[]]$regKeyApplication += $regKeyApplicationProps }
                    }
                    Catch {
                        Continue
                    }
                }
            }
        }

        ## Create a custom object with the desired properties for the installed applications and sanitize property details
        [psobject[]]$installedApplication = @()
        ForEach ($regKeyApp in $regKeyApplication) {
            Try {
                [string]$appDisplayName = ''
                [string]$appDisplayVersion = ''
                [string]$appPublisher = ''

                ## Bypass any updates or hotfixes
                If (($regKeyApp.DisplayName -match '(?i)kb\d+') -or ($regKeyApp.DisplayName -match 'Cumulative Update') -or ($regKeyApp.DisplayName -match 'Security Update') -or ($regKeyApp.DisplayName -match 'Hotfix')) {
                    Continue
                }

                ## Remove any control characters which may interfere with logging and creating file path names from these variables
                $appDisplayName = $regKeyApp.DisplayName -replace '[^\u001F-\u007F]', ''
                $appDisplayVersion = $regKeyApp.DisplayVersion -replace '[^\u001F-\u007F]', ''
                $appPublisher = $regKeyApp.Publisher -replace '[^\u001F-\u007F]', ''

                ## Determine if application is a 64-bit application
                [boolean]$Is64BitApp = If (($is64Bit) -and ($regKeyApp.PSPath -notmatch '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE\\SOFTWARE\\Wow6432Node')) { $true } Else { $false }

                If ($ProductCode) {
                    ## Verify if there is a match with the product code passed to the script
                    If ($regKeyApp.PSChildName -match [regex]::Escape($productCode)) {
                        $installedApplication += New-Object -TypeName 'PSObject' -Property @{
                            UninstallSubkey    = $regKeyApp.PSChildName
                            ProductCode        = If ($regKeyApp.PSChildName -match $MSIProductCodeRegExPattern) { $regKeyApp.PSChildName } Else { [string]::Empty }
                            DisplayName        = $appDisplayName
                            DisplayVersion     = $appDisplayVersion
                            UninstallString    = $regKeyApp.UninstallString
                            InstallSource      = $regKeyApp.InstallSource
                            InstallLocation    = $regKeyApp.InstallLocation
                            InstallDate        = $regKeyApp.InstallDate
                            Publisher          = $appPublisher
                            Is64BitApplication = $Is64BitApp
                        }
                    }
                }

                If ($name) {
                    ## Verify if there is a match with the application name(s) passed to the script
                    ForEach ($application in $Name) {
                        $applicationMatched = $false
                        #  Check for a contains application name match
                        If ($regKeyApp.DisplayName -match [regex]::Escape($application)) {
                            $applicationMatched = $true
                        }

                        If ($applicationMatched) {
                            $installedApplication += New-Object -TypeName 'PSObject' -Property @{
                                UninstallSubkey    = $regKeyApp.PSChildName
                                ProductCode        = If ($regKeyApp.PSChildName -match $MSIProductCodeRegExPattern) { $regKeyApp.PSChildName } Else { [string]::Empty }
                                DisplayName        = $appDisplayName
                                DisplayVersion     = $appDisplayVersion
                                UninstallString    = $regKeyApp.UninstallString
                                InstallSource      = $regKeyApp.InstallSource
                                InstallLocation    = $regKeyApp.InstallLocation
                                InstallDate        = $regKeyApp.InstallDate
                                Publisher          = $appPublisher
                                Is64BitApplication = $Is64BitApp
                            }
                        }
                    }
                }
            }
            Catch {
                Continue
            }
        }
        Write-Output -InputObject $installedApplication
    }
}

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name,
        [Parameter()]
        [string]
        $Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )
    Begin {
        Write-Log -message "[Set-RegistryValue]: Setting Registry Value: $Name"
    }
    Process {
        # Create the registry Key(s) if necessary.
        If (!(Test-Path -Path $Path)) {
            Write-Log -message "[Set-RegistryValue]: Creating Registry Key: $Path"
            New-Item -Path $Path -Force | Out-Null
        }
        # Check for existing registry setting
        $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($RemoteValue) {
            # Get current Value
            $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
            Write-Log -message "[Set-RegistryValue]: Current Value of $($Path)\$($Name) : $CurrentValue"
            If ($Value -ne $CurrentValue) {
                Write-Log -message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            } Else {
                Write-Log -message "[Set-RegistryValue]: Value of $($Path)\$($Name) is already set to $Value"
            }           
        }
        Else {
            Write-Log -message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    End {
    }
}

#endregion Functions
$Script:Name = 'Set-SessionHostConfiguration'
# from https://learn.microsoft.com/en-us/microsoftteams/new-teams-vdi-requirements-deploy#recommended-for-exclusion
# only specifying the folders that do not affect performance per article
$redirectionsXMLContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<FrxProfileFolderRedirection ExcludeCommonFolders="0">
<Excludes>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLog</Exclude>
<Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\GPUCache</Exclude>
<Exclude Copy="0">AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState</Exclude>
</Excludes>
<Includes>
</Includes>
</FrxProfileFolderRedirection>
'@

New-Log -Path (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
write-log -message "*** Parameter Values ***"
Write-Log -message "AmdVmSize: $AmdVmSize"
Write-Log -message "NvidiaVmSize: $NvidiaVmSize"
Write-Log -message "DisableUpdates: $DisableUpdates"
[bool]$ConfigureFSLogix = [System.Convert]::ToBoolean($ConfigureFSLogix)
Write-Log -message "ConfigureFSLogix: $ConfigureFSLogix"

#Convert CloudCache to Boolean
$CloudCache = [System.Convert]::ToBoolean($CloudCache)
Write-Log -message "CloudCache: $CloudCache"
#Convert Shares to Array
[array]$Shares = ConvertFrom-JsonString -JsonString $Shares -Name 'Shares'
$ProfileShareName = $Shares[0]
if ($Shares.Count -gt 1) {
    $OfficeShareName = $Shares[1]
} Else {
    $OfficeShareName = $null
}

Write-Log -message "ProfileShareName: $ProfileShareName"
Write-Log -message "OfficeShareName: $OfficeShareName"
Write-Log -message "StorageService: $StorageService"

$TeamsInstalled = Get-AppxProvisionedPackage -Online | Where-Object {$_.DisplayName -eq 'MSTeams'}
$M365AppsInstalled = Get-InstalledApplication -Name 'Microsoft 365 Apps'

if ($M365AppsInstalled) {
    Write-Log -message 'New Microsoft 365 Apps are installed on this image.'
}

if ($TeamsInstalled) {
    Write-Log -message 'New Teams Client is installed on this image.'
}

Write-Log -message "*** Building Array of Registry Settings ***"
$RegSettings = New-Object System.Collections.ArrayList
If ($DisableUpdates -eq 'true') {
    # Disable Automatic Updates: https://learn.microsoft.com/azure/virtual-desktop/set-up-customize-master-image#disable-automatic-updates
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; PropertyType = 'DWORD'; Value = 1})
    # Disable Edge Updates : https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies#updatedefault
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'UpdateDefault'; PropertyType = 'DWORD'; Value = 0})
    # Set the OneDrive Update Ring to Deferred: https://learn.microsoft.com/en-us/sharepoint/use-group-policy#set-the-sync-app-update-ring
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'GPOSetUpdateRing'; PropertyType = 'DWORD'; Value = 0})
    If ($M365AppsInstalled) {
        # Disable Office Automatic Updates: https://learn.microsoft.com/azure/virtual-desktop/set-up-customize-master-image#disable-office-automatic-updates
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'hideupdatenotifications'; PropertyType = 'DWORD'; Value = 1})
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; Name = 'hideenabledisableupdates'; PropertyType = 'DWORD'; Value = 1})
    }
    If ($TeamsInstalled) {
        # Disable Teams Auto-Update: https://learn.microsoft.com/en-us/microsoftteams/new-teams-vdi-requirements-deploy#disable-new-teams-autoupdate-in-non-persistent-vdi
        $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Microsoft\Teams'; Name = 'disableAutoUpdate'; PropertyType = 'DWORD'; Value = 1})
    }
}
# Enable Time Zone Redirection: https://learn.microsoft.com/azure/virtual-desktop/set-up-customize-master-image#set-up-time-zone-redirection
$RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'fEnableTimeZoneRedirection'; PropertyType = 'DWORD'; Value = 1})

##############################################################
#  Add GPU Settings
##############################################################
# This setting applies to the VM Size's recommended for AVD with a GPU
if ($AmdVmSize -eq 'true' -or $NvidiaVmSize -eq 'true') {
    Write-Log -message "Adding GPU Settings"
    # Configure GPU-accelerated app rendering: https://learn.microsoft.com/azure/virtual-desktop/configure-vm-gpu#configure-gpu-accelerated-app-rendering
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'bEnumerateHWBeforeSW'; PropertyType = 'DWORD'; Value = 1})
    # Configure fullscreen video encoding: https://learn.microsoft.com/azure/virtual-desktop/configure-vm-gpu#configure-fullscreen-video-encoding
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'AVC444ModePreferred'; PropertyType = 'DWORD'; Value = 1})
}

# This setting applies only to VM Size's recommended for AVD with a Nvidia GPU
if($NvidiaVmSize -eq 'true') {
    Write-Log -message "Adding Nvidia GPU Settings"
    # Configure GPU-accelerated frame encoding: https://learn.microsoft.com/azure/virtual-desktop/configure-vm-gpu#configure-gpu-accelerated-frame-encoding
    $RegSettings.Add(@{Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'; Name = 'AVChardwareEncodePreferred'; PropertyType = 'DWORD'; Value = 1})
}

If ($ConfigureFSLogix) {
    # Create Array Lists so it is easy to add them
    [System.Collections.ArrayList]$LocalProfileContainerPaths = @()
    [System.Collections.ArrayList]$LocalCloudCacheProfileContainerPaths = @()
    [System.Collections.ArrayList]$LocalOfficeContainerPaths = @()
    [System.Collections.ArrayList]$LocalCloudCacheOfficeContainerPaths = @()
    [System.Collections.ArrayList]$RemoteProfileContainerPaths = @()
    [System.Collections.ArrayList]$RemoteCloudCacheProfileContainerPaths = @()
    [System.Collections.ArrayList]$RemoteOfficeContainerPaths = @()
    [System.Collections.ArrayList]$RemoteCloudCacheOfficeContainerPaths = @()

    switch($StorageService) {
        'AzureFiles' {
            Write-Log -message "Gathering Azure Files Storage Account Parameters"
            # Convert escaped JSON strings to arrays
            [array]$OSSGroups = ConvertFrom-JsonString -JsonString $OSSGroups -Name 'OSSGroups'
            [array]$LocalStorageAccountNames = ConvertFrom-JsonString -JsonString $LocalStorageAccountNames -Name 'LocalStorageAccountNames'
            [array]$LocalStorageAccountKeys = ConvertFrom-JsonString -JsonString $LocalStorageAccountKeys -Name 'LocalStorageAccountKeys' -SensitiveValues
            [array]$RemoteStorageAccountNames = ConvertFrom-JsonString -JsonString $RemoteStorageAccountNames -Name 'RemoteStorageAccountNames'
            [array]$RemoteStorageAccountKeys = ConvertFrom-JsonString -JsonString $RemoteStorageAccountKeys -Name 'RemoteStorageAccountKeys' -SensitiveValues
            
            Write-Log -message "*** Begin Processing Storage Accounts ***"
            # Local Storage Accounts
            Write-Log -message "Processing Local Storage Accounts"
            For ($i = 0; $i -lt $LocalStorageAccountNames.Count; $i++) {
                $SAFQDN = "$($LocalStorageAccountNames[$i]).file.$StorageAccountDNSSuffix"
                Write-Log -message "LocalStorageAccountFQDN: '$SAFQDN'"
                If ($LocalStorageAccountKeys.Count -gt 0) {
                    If ($LocalStorageAccountKeys[$i]) {
                        Write-Log -message "Adding Local Storage Account Key for '$SAFQDN' to Credential Manager"
                        Start-Process -FilePath 'cmdkey.exe' -ArgumentList "/add:$SAFQDN /user:localhost\$($LocalStorageAccountNames[$i]) /pass:$($LocalStorageAccountKeys[$i])" -NoNewWindow -Wait
                    }
                }
                If ($OfficeShareName) {
                    $LocalOfficeContainerPaths.Add("\\$SAFQDN\$OfficeShareName")
                    Write-Log -message "LocalOfficeContainerPath: '\\$($SAFQDN)\$($OfficeShareName)'"                
                    $LocalCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($OfficeShareName)")
                    Write-Log -message "LocalCloudCacheOfficeContainerPath: 'type=smb,connectionString=\\$($SAFQDN)\$($OfficeShareName)'"
                }
                $LocalProfileContainerPaths.Add("\\$($SAFQDN)\$($ProfileShareName)")
                Write-Log -message "LocalProfileContainerPath: \\$($SAFQDN)\$($ProfileShareName)"
                $LocalCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)")
                Write-Log -message "LocalCloudCacheProfileContainerPath: 'type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)'"
            }
            # Remote / Existing Storage Accounts
            If ($RemoteStorageAccountNames.Count -gt 0) {
                Write-Log Info "Processing Remote Storage Accounts"
                For ($i = 0; $i -lt $RemoteStorageAccountNames.Count; $i++) {
                    $SAFQDN = "$($RemoteStorageAccountNames[$i]).file.$StorageAccountDNSSuffix"
                    Write-Log -message "RemoteStorageAccountFQDN: '$SAFQDN'"
                    If ($RemoteStorageAccountKeys.Count -gt 0) {
                        If ($RemoteStorageAccountKeys[$i]) {
                            Write-Log -message "Adding Remote Storage Account Key for '$SAFQDN' to Credential Manager"
                            Start-Process -FilePath 'cmdkey.exe' -ArgumentList "/add:$($SAFQDN) /user:localhost\$($RemoteStorageAccountNames[$i]) /pass:$($RemoteStorageAccountKeys[$i])" -NoNewWindow -Wait
                        }
                    }
                    If ($OfficeShareName) {
                        $RemoteOfficeContainerPaths.Add("\\$($SAFQDN)\$($OfficeShareName)")
                        Write-Log -message "RemoteOfficeContainerPath: '\\$($SAFQDN)\$($OfficeShareName)'"
                        $RemoteCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($OfficeShareName)")
                        Write-Log -message "RemoteCloudCacheOfficeContainerPath: 'type=smb,connectionString=\\$($SAFQDN)\$($OfficeShareName)"
                    }
                    $RemoteProfileContainerPaths.Add("\\$(SAFQDN)\$(ProfileShareName)")
                    Write-Log -message "RemoteProfileContainerPath: '\\$($SAFQDN)\$(ProfileShareName)'"
                    $RemoteCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)")
                    Write-Log -message "RemoteCloudCacheProfileContainerPath: 'type=smb,connectionString=\\$($SAFQDN)\$($ProfileShareName)'"
                }
            }
            Write-Log -message "Done Adding UNC Paths to arrays."
        }
        'AzureNetAppFiles' {
            Write-Log -message "Gathering Azure NetApp Files Storage Account Parameters"
            # Convert escaped JSON strings to arrays
            [array]$LocalNetAppServers = ConvertFrom-JsonString -JsonString $LocalNetAppServers -Name 'LocalNetAppServers'
            [array]$RemoteNetAppServers = ConvertFrom-JsonString -JsonString $RemoteNetAppServers -Name 'RemoteNetAppServers' 
            Write-Log -message "Processing Local Azure NetApp Servers"        
            $LocalProfileContainerPaths.Add("\\$($LocalNetAppServers[0])\$($ProfileShareName)")
            Write-Log -message "LocalProfileContainerPath: '\\$($LocalNetAppServers[0])\$($ProfileShareName)'"
            $LocalCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($LocalNetAppServers[0])\$($ProfileShareName)")
            Write-Log -message "LocalCloudCacheProfileContainerPath: 'type=smb,connectionString=\\$($LocalNetAppServers[0])\$($ProfileShareName)'"
            If($LocalNetAppServers.Length -gt 1 -and $OfficeShareName) {            
                $LocalOfficeContainerPaths.Add("\\$($LocalNetAppServers[1])\$($OfficeShareName)")
                Write-Log -message "LocalOfficeContainerPath: \\$($LocalNetAppServers[1])\$($OfficeShareName)"
                $LocalCloudCacheOfficeContainerPaths.Add("type=smb,connectionString=\\$($LocalNetAppServers[1])\$($OfficeShareName)")
                Write-Log -message "LocalCloudCacheOfficeContainerPath: 'type=smb,connectionString=\\$($LocalNetAppServers[1])\$($OfficeShareName)'"
            }
            
            If ($RemoteNetAppServers.Count -gt 0) {
                Write-Log -message "Processing Remote Azure NetApp Servers"
                $RemoteProfileContainerPaths.Add("\\$($RemoteNetAppServers[0])\$($ProfileShareName)")
                Write-Log -message "RemoteProfileContainerPath: '\\$($RemoteNetAppServers[0])\$($ProfileShareName)'"
                $RemoteCloudCacheProfileContainerPaths.Add("type=smb,connectionString=\\$($RemoteNetAppServers[0])\$($ProfileShareName)")
                Write-Log -message "RemoteCloudCacheProfileContainerPath: 'type=smb,connectionString=\\$($RemoteNetAppServers[0])\$($ProfileShareName)"
                If ($RemoteNetAppShares.Length -gt 1 -and $OfficeShareName) {
                    $RemoteOfficeContainerPaths.Add("\\$($RemoteNetAppServers[1])\$($OfficeShareName)")
                    Write-Log -message "RemoteOfficeContainerPath: '\\$($RemoteNetAppServers[1])\$($OfficeShareName)'"
                    $RemoteCloudCacheOfficeContainers.Add("type=smb,connectionString=\\$($RemoteNetAppServers[1])\$($OfficeShareName)")
                    Write-Log -message "RemoteCloudCacheOfficeContainerPath: 'type=smb,connectionString=\\$($RemoteNetAppServers[1])\$($OfficeShareName)'"
                }        
            }
        }
    }

    Write-Log -message "Adding Common FSLogix Settings"
    # Cleans up an invalid sessions to enable a successful sign-in: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=profiles#cleanupinvalidsessions
    $RegSettings.Add([PSCustomObject]@{ Name = 'CleanupInvalidSessions'; Path = 'HKLM:\SOFTWARE\FSLogix\Apps'; PropertyType = 'DWord'; Value = 1 })
    # Enables Fslogix profile containers: https://learn.microsoft.com/fslogix/profile-container-configuration-reference#enabled
    $RegSettings.Add([PSCustomObject]@{ Name = 'Enabled'; Path = 'HKLM:\SOFTWARE\Fslogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    # Deletes a local profile if it exists and matches the profile being loaded from VHD: https://learn.microsoft.com/fslogix/profile-container-configuration-reference#deletelocalprofilewhenvhdshouldapply
    $RegSettings.Add([PSCustomObject]@{ Name = 'DeleteLocalProfileWhenVHDShouldApply'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    # The folder created in the Fslogix fileshare will begin with the username instead of the SID: https://learn.microsoft.com/fslogix/profile-container-configuration-reference#flipflopprofiledirectoryname
    $RegSettings.Add([PSCustomObject]@{ Name = 'FlipFlopProfileDirectoryName'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    # Prevent Login with a failure: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=profiles#preventloginwithfailure
    $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithFailure'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    # Prevent Login with a temporary profile: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=profiles#preventloginwithtempprofile
    $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithTempProfile'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    # Specifies the number of seconds to wait between retries when attempting to reattach the VHD(x) container if it's disconnected unexpectedly: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=profiles#reattachintervalseconds
    $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachIntervalSeconds'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 15 })
    # Specifies the number of times the system should attempt to reattach the VHD(x) container if it's disconnected unexpectedly: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=profiles#reattachretrycount
    $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachRetryCount'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 3 })
    # Specifies the maximum size of the user's container in megabytes. Newly created VHD(x) containers are of this size: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=profiles#sizeinmbs
    $RegSettings.Add([PSCustomObject]@{ Name = 'SizeInMBs'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 30000 })
    # Specifies the file extension for the profile containers: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=profiles#volumetype
    $RegSettings.Add([PSCustomObject]@{ Name = 'VolumeType'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'String'; Value = 'VHDX' })

    If ($LocalStorageAccountKeys.Count -gt 0) {
        Write-Log -message "Adding AccessNetworkAsComputerObject for cloud only identities."
        # Attach the users VHD(x) as the computer: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=profiles#accessnetworkascomputerobject
        $RegSettings.Add([PSCustomObject]@{Name = 'AccessNetworkAsComputerObject'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    }

    if ($CloudCache -eq $True) {
        Write-Log -message "Adding Cloud Cache Settings"
        # Clear the cloud cache on logoff: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=ccd#clearcacheonlogoff
        $RegSettings.Add([PSCustomObject]@{ Name = 'ClearCacheOnLogoff'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'DWord'; Value = 1 })
    }

    If ($LocalOfficeContainerPaths.Count -gt 0) {
        Write-Log -message "Adding Office Container Settings"    
        # Enables Fslogix office containers: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#enabled-1   
        $RegSettings.Add([PSCustomObject]@{ Name = 'Enabled'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })   
        # The folder created in the Fslogix fileshare will begin with the username instead of the SID: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#flipflopprofiledirectoryname-1
        $RegSettings.Add([PSCustomObject]@{ Name = 'FlipFlopProfileDirectoryName'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
        # Specifies the number of retries attempted when a VHD(x) file is locked: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=odfc#lockedretrycount
        $RegSettings.Add([PSCustomObject]@{ Name = 'LockedRetryCount'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 3 })
        # Specifies the number of seconds to wait between retries: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=odfc#lockedretryinterval
        $RegSettings.Add([PSCustomObject]@{ Name = 'LockedRetryInterval'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 15 })
        # Prevent Login with a failure: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#preventloginwithfailure-1
        $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithFailure'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
        # Prevent Login with Temporary Profile: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#preventloginwithtempprofile-1
        $RegSettings.Add([PSCustomObject]@{ Name = 'PreventLoginWithTempProfile'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })    
        # Specifies the number of seconds to wait between retries when attempting to reattach the VHD(x) container if it's disconnected unexpectedly: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=odfc#reattachintervalseconds
        $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachIntervalSeconds'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 15 })
        # Specifies the number of times the system should attempt to reattach the VHD(x) container if it's disconnected unexpectedly: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=odfc#reattachretrycount
        $RegSettings.Add([PSCustomObject]@{ Name = 'ReAttachRetryCount'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 3 })
        # Specifies the maximum size of the user's container in megabytes: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=odfc#sizeinmbs
        $RegSettings.Add([PSCustomObject]@{ Name = 'SizeInMBs'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 30000 })
        # Specifies the type of container: https://learn.microsoft.com/fslogix/reference-configuration-settings?tabs=odfc#volumetype
        $RegSettings.Add([PSCustomObject]@{ Name = 'VolumeType'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'String'; Value = 'VHDX' })
        If ($LocalStorageAccountKeys.Count -gt 0) {
            Write-Log -message "Adding AccessNetworkAsComputerObject for cloud only identities."
            # Attach the users VHD(x) as the computer: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#accessnetworkascomputerobject-1
            $RegSettings.Add([PSCustomObject]@{ Name = 'AccessNetworkAsComputerObject'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
        }
        If ($CloudCache -eq $True) {
            Write-Log -message "Adding Cloud Cache Settings"
            # Clear the cloud cache on logoff: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=ccd#clearcacheonlogoff
            $RegSettings.Add([PSCustomObject]@{ Name = 'ClearCacheOnLogoff'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'DWord'; Value = 1 })
        }   
    }

    If ($OSSGroups.Count -gt 0) {
        Write-Log -message "Adding Object Specific Settings"
        # Object Specific Settings
        $DomainName = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty Domain
        Write-Log -message "DomainName: $DomainName"
        For ($i = 0; $i -lt $OSSGroups.Count; $i++) {
            # Get Domain information
            Write-Log -message "Getting SID for $($OSSGroups[$i])"        
            $OSSGroupSID = Convert-GroupToSID -DomainName $DomainName -GroupName $OSSGroups[$i]
            [string]$LocalProfileContainerPath = $LocalProfileContainerPaths[$i]
            Write-Log -message "LocalProfileContainerPath: '$LocalProfileContainerPath'"
            [string]$LocalCloudCacheProfileContainerPath = $LocalCloudCacheProfileContainerPaths[$i]
            Write-Log -message "LocalCloudCacheProfileContainerPath: '$LocalCloudCacheProfileContainerPath'"

            If ($RemoteStorageAccountNames) {
                [string]$RemoteProfileContainerPath = $RemoteProfileContainerPaths[$i]
                Write-Log -message "RemoteProfileContainerPath: '$RemoteProfileContainerPath'"
                [string]$RemoteCloudCacheProfileContainerPath = $RemoteCloudCacheProfilePaths[$i]
                Write-Log -message "RemoteCloudCacheProfileContainerPath: '$RemoteCloudCacheProfileContainerPath'"
                [array]$ProfileContainerPaths = @($LocalProfileContainerPath + $RemoteProfileContainerPath)
                [array]$CloudCacheProfileContainerPaths = @($LocalCloudCacheProfileContainerPath + $RemoteCloudCacheProfileContainerPath)
            } Else {
                [array]$ProfileContainerPaths = @($LocalProfileContainerPath)
                [array]$CloudCacheProfileContainerPaths = @($LocalCloudCacheProfileContainerPath)
            }

            If ($CloudCache -eq $True) {
                Write-Log -message "Adding Cloud Cache Profile Container Settings: $OSSGroupSID : '$($CloudCacheProfileContainerPaths -join "', '")'"
                # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=ccd#ccdlocations
                $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = "HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $CloudCacheProfileContainerPaths })
            } Else {
                Write-Log -message "Adding Profile Container Settings: $OSSGroupSID : '$($ProfileContainerPaths -join "', '")'"
                # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/fslogix/profile-container-configuration-reference#vhdlocations
                $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = "HKLM:\SOFTWARE\FSLogix\Profiles\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $ProfileContainerPaths })
            }   

            If ($LocalOfficeContainerPaths.Count -gt 0) {
                [string]$LocalOfficeContainerPath = $LocalOfficeContainerPaths[$i]
                Write-Log -message "LocalOfficeContainerPath: '$LocalOfficeContainerPath'"
                [string]$LocalCloudCacheOfficeContainerPath = $LocalCloudCacheOfficeContainerPaths[$i]
                Write-Log -message "LocalCloudCacheOfficeContainerPath: '$LocalCloudCacheOfficeContainerPath'"
                If ($RemoteStorageAccountNames) {
                    [string]$RemoteOfficeContainerPath = $RemoteOfficeContainerPaths[$i]
                    Write-Log -message "RemoteOfficeContainerPath: '$RemoteOfficeContainerPath'"
                    [string]$RemoteCloudCacheOfficeContainerPath = $RemoteCloudCacheOfficePaths[$i]
                    Write-Log -message "RemoteCloudCacheOfficeContainerPath: '$RemoteCloudCacheOfficeContainerPath'"
                    [array]$OfficeContainerPaths = @($LocalOfficeContainerPath + $RemoteOfficeContainerPath)
                    [array]$CloudCacheOfficeContainerPaths = @($LocalCloudCacheOfficeContainerPath + $RemoteCloudCacheOfficeContainerPath)
                } Else {
                    [array]$OfficeContainerPaths = @($LocalOfficeContainerPath)
                    [array]$CloudCacheOfficeContainerPaths = @($LocalCloudCacheOfficeContainerPath)
                }
                If ($CloudCache -eq $True) {
                    Write-Log -message "Adding Cloud Cache Office Container Settings: $OSSGroupSID : '$($CloudCacheOfficeContainerPaths -join "', '")'"
                    # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=ccd#ccdlocations
                    $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = "HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $CloudCacheOfficeContainerPaths })
                } Else {
                    Write-Log -message "Adding Office Container Settings: $OSSGroupSID : '$($OfficeContainerPaths -join "', '")'"
                    # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#vhdlocations-1
                    $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = "HKLM:\SOFTWARE\Policies\FSLogix\ODFC\ObjectSpecific\$OSSGroupSID"; PropertyType = 'MultiString'; Value = $OfficeContainerPaths })
                }
            }  
        }          
    } Else {
        If ($RemoteStorageAccountNames.Count -gt 0) {
            $ProfileContainerPaths = $LocalProfileContainerPaths + $RemoteProfileContainerPaths
            $CloudCacheProfileContainerPaths = $LocalCloudCacheProfileContainerPaths + $RemoteCloudCacheProfileContainerPaths
        } Else {
            $ProfileContainerPaths = $LocalProfileContainerPaths
            $CloudCacheProfileContainerPaths = $LocalCloudCacheProfileContainerPaths
        }
        If ($CloudCache -eq $True) {
            Write-Log -message "Adding Cloud Cache Profile Container Settings: '$($CloudCacheProfileContainerPaths -join "', '")'"   
            # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=ccd#ccdlocations 
            $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'MultiString'; Value = $CloudCacheProfileContainerPaths })             
        } Else {
            Write-Log -message "Adding Profile Container Settings: '$($ProfileContainerPaths -join "', '")'"
            # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/fslogix/profile-container-configuration-reference#vhdlocations
            $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = 'HKLM:\SOFTWARE\FSLogix\Profiles'; PropertyType = 'MultiString'; Value = $ProfileContainerPaths })
        }
        If ($LocalOfficeContainerPaths.Count -gt 0) {
            If ($RemoteStorageAccountNames.Count -gt 0) {
                $OfficeContainerPaths = $LocalOfficeContainerPaths + $RemoteOfficeContainerPaths
                $CloudCacheOfficeContainerPaths = $LocalCloudCacheOfficeContainerPaths + $RemoteCloudCacheOfficeContainerPaths
            } Else {
                $OfficeContainerPaths = $LocalOfficeContainerPaths
                $CloudCacheOfficeContainerPaths = $LocalCloudCacheOfficeContainerPaths
            }
            If ($CloudCache -eq $True) {
                Write-Log -message "Adding Cloud Cache Office Container Settings: '$($CloudCacheOfficeContainerPaths -join "', '")'"
                # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=ccd#ccdlocations
                $RegSettings.Add([PSCustomObject]@{ Name = 'CCDLocations'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'MultiString'; Value = $CloudCacheOfficeContainerPaths })
            } Else {
                Write-Log -message "Adding Office Container Settings: '$($OfficeContainerPaths -join "', '")'"
                # List of file system locations to search for the user's profile VHD(X) file: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=odfc#vhdlocations-1
                $RegSettings.Add([PSCustomObject]@{ Name = 'VHDLocations'; Path = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'; PropertyType = 'MultiString'; Value = $OfficeContainerPaths })
            }
        }    
    }
    Write-Log -message "Checking for Teams"
    If ($TeamsInstalled) {
        Write-Log -message "Teams is installed"
        $customRedirFolder = "$env:ProgramData\FSLogix_CustomRedirections"
        Write-Log -message "Creating custom redirections.xml file in $customRedirFolder"
        If (-not (Test-Path $customRedirFolder )) {
            New-Item -Path $customRedirFolder -ItemType Directory -Force
        }
        $customRedirFilePath = "$customRedirFolder\redirections.xml"
        $redirectionsXMLContent | Out-File -FilePath $customRedirFilePath -Encoding unicode
        # Path where FSLogix looks for the redirections.xml file to copy from and into the user's profile: https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=profiles#redirxmlsourcefolder
        
        $RegSettings.Add(
            [PSCustomObject]@{
                Name         = 'RedirXMLSourceFolder'
                Path         = 'HKLM:\SOFTWARE\FSLogix\Profiles'
                PropertyType = 'String'
                Value        = $customRedirFolder
            }
        )
    }

    $LocalAdministrator = (Get-LocalUser | Where-Object { $_.SID -like '*-500' }).Name
    $LocalGroups = 'FSLogix Profile Exclude List', 'FSLogix ODFC Exclude List'
    ForEach ($Group in $LocalGroups) {
        If (-not (Get-LocalGroupMember -Group $Group | Where-Object { $_.Name -like "*$LocalAdministrator" })) {
            Add-LocalGroupMember -Group $Group -Member $LocalAdministrator
        }
    }
}

Write-Log -message "*** Setting Registry Values ***"
ForEach ($Setting in $RegSettings) {
    Set-RegistryValue -Name $Setting.Name -Path $Setting.Path -PropertyType $Setting.PropertyType -Value $Setting.Value -Verbose
}

# Resize OS Disk
Write-Log -message "Resizing OS Disk"
$driveLetter = $env:SystemDrive.Substring(0,1)
$size = Get-PartitionSupportedSize -DriveLetter $driveLetter
Resize-Partition -DriveLetter $driveLetter -Size $size.SizeMax
Write-Log -message "OS Disk Resized"
Clear-EventLog "Windows PowerShell" -ErrorAction SilentlyContinue
Write-Log -message "Done"
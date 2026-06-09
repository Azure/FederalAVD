<#
.SYNOPSIS
    This script uses the local group policy object tool (lgpo.exe) to apply the applicable DISA STIGs GPOs either downloaded directly from CyberCom or
    the files are contained with this script in the root of a folder.

.PARAMETER ApplicationsToSTIG
    This parameter defines the third party applications that should be STIGd by this script. This needs to be defined as a JSON string to support Run Commands.

.PARAMETER SearchForApplications
    This parameter defines whether or not the script verifies the applications defined in 'ApplicationsToSTIG' are installed before applying the settings.

.PARAMETER CloudOnly
    This parameter defines whether or not cloud only identity is used on the system with fslogix. If selected then the system will be able to use cmdkey to save the storage account key.

.PARAMETER STIGsUrl
    This parameter defines the URL of the STIG GPOs ZIP file to be downloaded and applied.

.PARAMETER Upgrade
    This parameter indicates that the script will check the STIG version and reset the local group policy before applying the STIGs if the version has changed.

.PARAMETER Version
    This parameter defines the STIG version to be stamped to the registry (format: YYYY.MM, e.g., 2025.10). Used for version tracking and upgrade detection.

.NOTES
    To use this script offline, download the lgpo tool from 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' and store it in the root of the folder where the script is located.'
    to the root of the folder where this script is located. Then download the latest STIG GPOs ZIP from 'https://public.cyber.mil/stigs/gpo' and it to the root
    of the folder where this script is located.

    This script not only applies the GPO objects but it also applies some registry settings and other mitigations. Ensure that these other items still apply through the
    lifecycle of the script.
#>
[CmdletBinding()]
param (
    [string]$ApplicationsToSTIG = '["Adobe Acrobat Pro", "Adobe Acrobat Reader", "Google Chrome", "Mozilla Firefox"]',
    
    [string]$SearchForApplications = 'False',

    [string]$CloudOnly = 'True',

    [string]$STIGsUrl = 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2025.zip',

    [string]$Upgrade = 'False',

    [string]$Version = '2025.10'
)
#region Initialization
$Script:Name = 'Apply-STIGs'
[string]$LGPOUrl = 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip'
$osCaption = (Get-WmiObject -Class Win32_OperatingSystem).caption
If ($osCaption -match 'Windows 11') { $osVersion = 11 } Else { $osVersion = 10 }
[string]$Script:TempDir = Join-Path -Path "$env:SystemRoot\Temp" -ChildPath $Script:Name
[string]$Script:LGPOTempDir = Join-Path -Path $Script:TempDir -ChildPath 'LGPO'
If (-not(Test-Path -Path $Script:LGPOTempDir)) { New-Item -Path $Script:LGPOTempDir -ItemType Directory -Force | Out-Null }

If ($ApplicationsToSTIG -ne $null) { 
    [array]$ApplicationsToSTIG = $ApplicationsToSTIG.replace('\', '') | ConvertFrom-Json
}
[bool]$CloudOnly = $CloudOnly.ToLower() -eq 'true'
[bool]$SearchForApplications = $SearchForApplications.ToLower() -eq 'true'
[bool]$Upgrade = $Upgrade.ToLower() -eq 'true'
[bool]$IsDomainJoined = (Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain
#endregion

#region Functions

Function Get-InstalledApplication {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullorEmpty()]
        [string[]]$Name
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
                                SearchString       = $application
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

Function Get-InternetFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [uri]$Url,
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $false, Position = 2)]
        [string]$OutputFileName
    )

    Begin {
        $ProgressPreference = 'SilentlyContinue'
        ## Get the name of this function and write header
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        Write-Log -Message "Starting ${CmdletName} with the following parameters: $PSBoundParameters"
    }
    Process {

        $start_time = Get-Date

        If (!$OutputFileName) {
            Write-Log -Message "${CmdletName}: No OutputFileName specified. Trying to get file name from URL."
            If ((split-path -path $Url -leaf).Contains('.')) {
                $OutputFileName = split-path -path $url -leaf
                Write-Log -Message "${CmdletName}: Url contains file name - '$OutputFileName'."
            }
            Else {
                Write-Log -Message "${CmdletName}: Url does not contain file name. Trying 'Location' Response Header."
                $request = [System.Net.WebRequest]::Create($url)
                $request.AllowAutoRedirect = $false
                $response = $request.GetResponse()
                $Location = $response.GetResponseHeader("Location")
                If ($Location) {
                    $OutputFileName = [System.IO.Path]::GetFileName($Location)
                    Write-Log -Message "${CmdletName}: File Name from 'Location' Response Header is '$OutputFileName'."
                }
                Else {
                    Write-Log -Message "${CmdletName}: No 'Location' Response Header returned. Trying 'Content-Disposition' Response Header."
                    $result = Invoke-WebRequest -Method GET -Uri $Url -UseBasicParsing
                    $contentDisposition = $result.Headers.'Content-Disposition'
                    If ($contentDisposition) {
                        $OutputFileName = $contentDisposition.Split("=")[1].Replace("`"", "")
                        Write-Log -Message "${CmdletName}: File Name from 'Content-Disposition' Response Header is '$OutputFileName'."
                    }
                }
            }
        }

        If ($OutputFileName) { 
            $wc = New-Object System.Net.WebClient
            $OutputFile = Join-Path $OutputDirectory $OutputFileName
            Write-Log -Message "${CmdletName}: Downloading file at '$url' to '$OutputFile'."
            Try {
                $wc.DownloadFile($url, $OutputFile)
                $time = (Get-Date).Subtract($start_time).Seconds
                
                Write-Log -Message "${CmdletName}: Time taken: '$time' seconds."
                if (Test-Path -Path $outputfile) {
                    $totalSize = (Get-Item $outputfile).Length / 1MB
                    Write-Log -Message "${CmdletName}: Download was successful. Final file size: '$totalsize' mb"
                    Return $OutputFile
                }
            }
            Catch {
                Write-Log -Category Error -Message "${CmdletName}: Error downloading file. Please check url."
                Return $Null
            }
        }
        Else {
            Write-Log -Category Error -Message "${CmdletName}: No OutputFileName specified. Unable to download file."
            Return $Null
        }
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
    }
}

Function Update-LocalGPOTextFile {
    <#
    .SYNOPSIS
        Appends a single registry policy entry to an LGPO text file (lgpo.exe /t format).
    .DESCRIPTION
        Builds up Computer.txt or User.txt in the specified output directory.
        Each call appends one 4-line block (scope, key path, value name, data/DELETE)
        followed by a blank line.  Pass the resulting file to 'lgpo.exe /t <file>'.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [ValidateSet('Computer', 'User')]
        [string]$Scope,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [string]$RegistryKeyPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [string]$RegistryValue,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [AllowEmptyString()]
        [string]$RegistryData,
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [ValidateSet('DWORD', 'String')]
        [string]$RegistryType,
        [Parameter(Mandatory = $false, ParameterSetName = 'Delete')]
        [switch]$Delete,
        [Parameter(Mandatory = $false, ParameterSetName = 'DeleteAllValues')]
        [switch]$DeleteAllValues,
        [string]$OutputFile = ''
    )
    [string]$CmdletName = $PSCmdlet.MyInvocation.MyCommand.Name
    # Convert type to uppercase; LGPO text format uses SZ not STRING
    $ValueType = $RegistryType.ToUpper()
    If ($ValueType -eq 'STRING') { $ValueType = 'SZ' }

    # Strip any PowerShell-style drive prefixes (HKLM:\, HKCU:\, etc.)
    $SearchStrings = 'HKLM:\', 'HKCU:\', 'HKEY_CURRENT_USER:\', 'HKEY_LOCAL_MACHINE:\'
    $modified = $false
    ForEach ($String in $SearchStrings) {
        If ($RegistryKeyPath.StartsWith($String) -and -not $modified) {
            $RegistryKeyPath = $RegistryKeyPath.Substring($String.Length)
            $modified = $true
        }
    }

    # Default output path: $Script:LGPOTempDir\<Scope>.txt
    # Callers can override with -OutputFile to keep the path explicit.
    If ([string]::IsNullOrEmpty($OutputFile)) {
        $OutputFile = Join-Path -Path $Script:LGPOTempDir -ChildPath "$Scope.txt"
    }
    $OutDir = Split-Path -Path $OutputFile -Parent
    If (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        $null = New-Item -Path $OutDir -ItemType Directory -Force -ErrorAction Stop
    }
    If (-not (Test-Path -LiteralPath $OutputFile)) {
        $null = New-Item -Path $OutputFile -ItemType File -ErrorAction Stop
    }
    Write-Log -Message "${CmdletName}: Adding '$RegistryValue' to '$OutputFile'"
    Add-Content -Path $OutputFile -Value $Scope
    Add-Content -Path $OutputFile -Value $RegistryKeyPath
    Add-Content -Path $OutputFile -Value $RegistryValue
    If ($Delete)              { Add-Content -Path $OutputFile -Value 'DELETE' }
    ElseIf ($DeleteAllValues) { Add-Content -Path $OutputFile -Value 'DELETEALLVALUES' }
    Else                      { Add-Content -Path $OutputFile -Value "$($ValueType):$RegistryData" }
    Add-Content -Path $OutputFile -Value ''
}

Function New-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [string] $Path = (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
    )

    # Create central log file with given date

    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

Function Reset-LocalPolicy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [switch] $ResetSecurity,         # Also reset Local Security Policy via secedit
        [switch] $SkipGpUpdate          # Skip gpupdate /force if you plan to reboot
    )

    begin {
        $ErrorActionPreference = 'Stop'
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        $gpPath = Join-Path $env:windir 'System32\GroupPolicy' # LGPO (Computer/User Administrative Templates)
    }
    process {
        Write-Log -message "${CmdletName}: Resetting Local Group Policy..."

        if (Test-Path -LiteralPath $gpPath) {
            Write-Log -message "${CmdletName}: Removing: $gpPath"
            Remove-Item -LiteralPath $gpPath -Recurse -Force -ErrorAction Stop
        }
        else {
            Write-Log -message "${CmdletName}: Path not found (already clean): $gpPath"
        }
        
        if ($ResetSecurity) {
            Write-Log -message "${CmdletName}: Resetting Local Security Policy..."
            # Use defltbase.inf to restore default security baseline (Vista+)
            $cfg = Join-Path $env:windir 'inf\defltwk.inf'
            if (-not (Test-Path -LiteralPath $cfg)) {
                throw "Default security template not found: $cfg"
            }
            Write-Log -message "${CmdletName}: Running secedit to reset Local Security Policy to defaults..."
            $cmd = "secedit /configure /cfg `"$cfg`" /db defltbase.sdb /verbose"
            $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmd" -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                throw "secedit returned non-zero exit code: $($proc.ExitCode)"
            }
        }
        else {
            Write-Log -message "${CmdletName}: Skipping Local Security Policy reset. (Use -ResetSecurity to include.)"
        }

        if (-not $SkipGpUpdate) {
            Write-Log -message "${CmdletName}: Forcing policy refresh (gpupdate /force)..."
            $gp = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c gpupdate /force' -Wait -PassThru
            if ($gp.ExitCode -ne 0) {
                Write-Log -Category Warning -Message "${CmdletName}: gpupdate returned non-zero exit code: $($gp.ExitCode)"
            }
        }
        else {
            Write-Log -Messagee "${CmdletName}: Skipping gpupdate. (A reboot will also reapply policies.)"
        }
    }
    end {
        Write-Log -message "Completed ${CmdletName}."
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
            }
            Else {
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

Function Disable-OptionalFeatureIfEnabled {
    <#
    .SYNOPSIS
        Disables a Windows Optional Feature only if it is currently enabled.
        Silently no-ops when the feature is absent or already disabled.
    #>
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][string]$StigId
    )
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -eq 'Enabled') {
        Write-Log -Message "${StigId}: Disabling Windows Optional Feature '$FeatureName'."
        Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-Log -Message "${StigId}: '$FeatureName' is already disabled or not present. No action required."
    }
}

Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $Date = get-date
    $Content = "[$Date]`t$Category`t`t$Message" 
    Add-Content $Script:Log $content -ErrorAction Stop
    If ($Verbose) {
        Write-Verbose $Content
    }
    Else {
        Switch ($Category) {
            'Info' { Write-Host $content }
            'Error' { Write-Error $Content }
            'Warning' { Write-Warning $Content }
        }
    }
}
#endregion

#region Main

New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
Write-Log -Message "Starting '$PSCommandPath'."
Write-Log -Category Info -Message "Parameters: ApplicationsToSTIG: $($ApplicatonsToSTIG -join ','), CloudOnly: $CloudOnly, Upgrade: $Upgrade, Version: $Version"

# Use provided version parameter
[version]$stigVersion = $Version
If ($stigVersion) {
    Write-Log -Message "STIG Version: $stigVersion"
}
Else {
    Write-Log -Category Warning -Message "No STIG version provided. Version tracking will be skipped."
}

# Check registry for existing version and determine if reset is needed
$registryPath = 'HKLM:\Software\DoD\STIG'
$registryValueName = 'Version'
$needsReset = $false

If ($Upgrade) {
    Write-Log -Message "Upgrade mode enabled. Checking for version mismatch."
    If (Test-Path -Path $registryPath) {
        Try {
            $existingVersion = Get-ItemPropertyValue -Path $registryPath -Name $registryValueName -ErrorAction SilentlyContinue
            If ($existingVersion) {
                [version]$appliedVersion = $existingVersion
                Write-Log -Message "Existing STIG version in registry: $existingVersion"
                If ($stigVersion -and $appliedVersion -ne $stigVersion) {
                    Write-Log -Message "Version mismatch detected. Applied: $appliedVersion, New: $stigVersion. Policy reset will be performed."
                    $needsReset = $true
                }
                Else {
                    Write-Log -Message "Version matches. No policy reset needed."
                }
            }
            Else {
                Write-Log -Message "No existing version found in registry. Policy reset will be performed."
                $needsReset = $true
            }
        }
        Catch {
            Write-Log -Message "Error reading registry version: $_. Policy reset will be performed."
            $needsReset = $true
        }
    }
    Else {
        Write-Log -Message "Registry path does not exist. Policy reset will be performed."
        $needsReset = $true
    }

    # Perform policy reset if needed
    If ($needsReset) {
        Write-Log -Message "Resetting Local Group Policy before applying new STIGs."
        Try {
            Reset-LocalPolicy -ResetSecurity -Verbose
            Write-Log -Message "Local Group Policy reset completed successfully."
        }
        Catch {
            Write-Log -Category Error -Message "Error resetting Local Group Policy: $_"
        }
    }
}

Write-Log -message "Checking for 'lgpo.exe' in '$env:SystemRoot\system32'."

If (-not(Test-Path -Path "$env:SystemRoot\System32\lgpo.exe")) {
    Write-Log -category Info -message "'lgpo.exe' not found in '$env:SystemRoot\system32'."
    $LGPOZip = Join-Path -Path $PSScriptRoot -ChildPath 'LGPO.zip'
    If (-not(Test-Path -Path $LGPOZip)) {
        Write-Log -category Info -Message "Downloading LGPO tool."
        $LGPOZip = Get-InternetFile -Url $LGPOUrl -OutputDirectory $Script:TempDir -Verbose    
    }
    Write-Log -Category Info -Message "Expanding '$LGPOZip' to '$Script:TempDir'."
    Expand-Archive -Path $LGPOZip -DestinationPath $Script:TempDir -Force
    $fileLGPO = (Get-ChildItem -Path $Script:TempDir -Filter 'lgpo.exe' -Recurse)[0].FullName
    Write-Log -Message "Copying '$fileLGPO' to '$env:SystemRoot\system32'."
    Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -Force
}
$stigZip = Get-ChildItem -Path $PSScriptRoot -Filter '*.zip' | Where-Object { $_.Name -notmatch 'LGPO.zip' } | Select-Object -First 1
If ($stigZip) {
    $stigZip = $stigZip.FullName
    Write-Log -Message "Using existing STIG GPOs ZIP file found at '$stigZip'."
}
If (-not ($stigZip)) {
    #Download the STIG GPOs
    Write-Log -Message "Downloading STIG GPOs from '$STIGsUrl'."
    $stigZip = Get-InternetFile -url $STIGsUrl -OutputDirectory $Script:TempDir -Verbose
    If ($null -eq $stigZip) { Write-Log -Category Error -Message "Unable to download STIG GPOs. Exiting script."; Exit 1 }
} 

Expand-Archive -Path $stigZip -DestinationPath $Script:TempDir -Force
Write-Log -Message "Copying ADMX and ADML files to local system."

$null = Get-ChildItem -Path $Script:TempDir -File -Recurse -Filter '*.admx' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
$null = Get-ChildItem -Path $Script:TempDir -Directory -Recurse | Where-Object { $_.Name -eq 'en-us' } | Get-ChildItem -File -recurse -filter '*.adml' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }

Write-Log -Message "Getting List of Applicable GPO folders."

$STIGFolders = Get-ChildItem -Path $Script:TempDir -Directory
[array]$ApplicableFolders = $STIGFolders | Where-Object { $_.Name -like "DoD*Windows $osVersion*" -or $_.Name -like 'DoD*Edge*' -or $_.Name -like 'DoD*Firewall*' -or $_.Name -like 'DoD*Internet Explorer*' -or $_.Name -like 'DoD*Defender Antivirus*' }
If (Get-InstalledApplication -Name 'Microsoft 365', 'Office', 'Teams') {
    $ApplicableFolders += $STIGFolders | Where-Object { $_.Name -match 'M365' } 
}
If ($SearchForApplications) {
    Write-Log -Message "Searching for applications to STIG."
    $InstalledAppsToSTIG = (Get-InstalledApplication -Name $ApplicationsToSTIG).SearchString
    ForEach ($SearchString in $InstalledAppsToSTIG) {
        $ApplicableFolders += $STIGFolders | Where-Object { $_.Name -match "$SearchString" }
    }
}
Else {
    Write-Log -Message "Skipping application search."
    ForEach ($AppSearchString in $ApplicationsToSTIG) {
        $ApplicableFolders += $STIGFolders | Where-Object { $_.Name -match "$AppSearchString" }
    }
}

Write-Log -Message "Found $($ApplicableFolders.Count) applicable GPO folders:"
$ApplicableFolders | ForEach-Object { Write-Log -Message "  $_" } 
[array]$GPOFolders = @()
ForEach ($folder in $ApplicableFolders.FullName) {
    $gpoFolderPath = (Get-ChildItem -Path $folder -Filter 'GPOs' -Directory).FullName
    $GPOFolders += $gpoFolderPath
}
ForEach ($gpoFolder in $GPOFolders) {
    If ($gpoFolder -match "DoD Windows $osVersion") {
        <# Remove the policies that disable and rename the administrator account.
            # this should be done via the following code in run commands.
            
            # Get the built-in Administrator account (RID 500)
            $adminAccount = Get-LocalUser | Where-Object { $_.SID -like "*-500" }

            # Rename the Administrator account
            Rename-LocalUser -Name $adminAccount.Name -NewName $newAdminName

            # Disable the renamed account
            Disable-LocalUser -Name $newAdminName
        #>
        $SecEditFile = (Get-ChildItem -Path $gpoFolder -Recurse -Filter "GptTmpl.inf" | Where-Object { $_.DirectoryName -match "SecEdit" }).FullName
        $Content = Get-Content $SecEditFile
        Write-Output "Applying AVD exceptions to DoD Windows $osVersion security template: $SecEditFile"

        # Remove administrator account disable/rename lines
        $Content | Where-Object { ($_ -like 'NewAdministratorName*') -or ($_ -like 'EnableAdminAccount*') } |
            ForEach-Object { Write-Output "  [GptTmpl] REMOVED : $_" }
        $Content = $Content | Where-Object { (-not ($_ -like 'NewAdministratorName*')) -and (-not ($_ -like 'EnableAdminAccount*')) }

        # Replace or remove the 'ADD YOUR ENTERPRISE ADMINS' / 'ADD YOUR DOMAIN ADMINS'
        # placeholder tokens that the DoD STIG GPO leaves in the [Privilege Rights] section.
        if ($IsDomainJoined) {
            $Content | Where-Object { $_ -match 'ADD YOUR ENTERPRISE ADMINS|ADD YOUR DOMAIN ADMINS' } | ForEach-Object {
                $replaced = $_ -replace 'ADD YOUR ENTERPRISE ADMINS', 'Enterprise Admins' -replace 'ADD YOUR DOMAIN ADMINS', 'Domain Admins'
                Write-Output "  [GptTmpl] BEFORE  : $_"
                Write-Output "  [GptTmpl] AFTER   : $replaced"
            }
            $Content = $Content -replace 'ADD YOUR ENTERPRISE ADMINS', 'Enterprise Admins'
            $Content = $Content -replace 'ADD YOUR DOMAIN ADMINS', 'Domain Admins'
        } else {
            $Content | Where-Object { $_ -match 'ADD YOUR ENTERPRISE ADMINS|ADD YOUR DOMAIN ADMINS' } | ForEach-Object {
                $cleaned = $_ -replace ",\s*ADD YOUR ENTERPRISE ADMINS", '' -replace "ADD YOUR ENTERPRISE ADMINS\s*,", '' -replace 'ADD YOUR ENTERPRISE ADMINS', ''
                $cleaned = $cleaned -replace ",\s*ADD YOUR DOMAIN ADMINS", '' -replace "ADD YOUR DOMAIN ADMINS\s*,", '' -replace 'ADD YOUR DOMAIN ADMINS', ''
                Write-Output "  [GptTmpl] BEFORE  : $_"
                Write-Output "  [GptTmpl] AFTER   : $cleaned"
            }
            foreach ($placeholder in @('ADD YOUR ENTERPRISE ADMINS', 'ADD YOUR DOMAIN ADMINS')) {
                $escaped = [regex]::Escape($placeholder)
                $Content = $Content -replace ",\s*$escaped", ''
                $Content = $Content -replace "$escaped\s*,", ''
                $Content = $Content -replace $escaped, ''
            }
        }

        # Set SeRemoteInteractiveLogonRight to allow RDS Users (S-1-5-32-555) and Administrators
        # (S-1-5-32-544). The STIG restricts this to Administrators only; AVD requires RDS Users
        # so that session host connections can be established.
        $Content | Where-Object { $_ -like 'SeRemoteInteractiveLogonRight*' } | ForEach-Object {
            Write-Output "  [GptTmpl] BEFORE  : $_"
            Write-Output "  [GptTmpl] AFTER   : SeRemoteInteractiveLogonRight = *S-1-5-32-555,*S-1-5-32-544"
        }
        $Content = $Content | ForEach-Object {
            if ($_ -like 'SeRemoteInteractiveLogonRight*') { 'SeRemoteInteractiveLogonRight = *S-1-5-32-555,*S-1-5-32-544' } else { $_ }
        }

        # When CloudOnly, allow Windows Credential Manager to store credentials for mapped
        # storage accounts (e.g. FSLogix Azure Files UNC paths).  The STIG sets
        # DisableDomainCreds=4,1 (block credential storage); cloud-only AVD needs 4,0 (allow).
        if ($CloudOnly) {
            $Content | Where-Object { $_ -like '*DisableDomainCreds*' } | ForEach-Object {
                Write-Output "  [GptTmpl] BEFORE  : $_"
                Write-Output "  [GptTmpl] AFTER   : $($_ -replace '4,1', '4,0')"
            }
            $Content = $Content | ForEach-Object {
                if ($_ -like '*DisableDomainCreds*') { $_ -replace '4,1', '4,0' } else { $_ }
            }
        }

        Set-Content -Path $SecEditFile -Value $Content -Encoding Unicode
    }
    Write-Log -Message "Running 'LGPO.exe /g `"$gpoFolder`"'"
    $lgpo = Start-Process -FilePath "$env:SystemRoot\System32\lgpo.exe" -ArgumentList "/g `"$gpoFolder`"" -Wait -PassThru
    Write-Log -Message "'lgpo.exe' exited with code [$($lgpo.ExitCode)]."
}

Write-Log -Message "Applying AVD Administrative Template-based Exceptions"

# ── EccCurves exception (WN11-CC-000195 → V-253363) ──────────────────────────
# The DoD Windows 11 STIG GPO (WN11-CC-000195) sets the EccCurves policy value
# under HKLM\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002
# to restrict TLS elliptic curves to NistP384 only (NSA Suite B).
#
# This BREAKS Azure Virtual Desktop because:
#   - The AVD gateway, broker, and control plane endpoints negotiate TLS using
#     ECDHE with P-256 (NistP256).
#   - When EccCurves is locked to NistP384, the TLS handshake fails because
#     there is no common curve to negotiate with the Azure service endpoints.
#   - Symptoms: AVD agent fails to register the session host with the host pool;
#     active sessions disconnect; the RD Gateway connection itself fails.
#
# The fix is to DELETE this policy value so Windows falls back to its default
# curve list, which includes both NistP256 and NistP384.
#
# Note: The ideal long-term fix would be to explicitly set EccCurves to
# "NistP256 NistP384" (both curves) rather than deleting the key entirely.
# Deleting restores the full Windows default list which includes some older
# curves. However, DELETE is the approach used by all current DoD AVD STIG
# guidance and is the most operationally safe option until Microsoft aligns
# AVD endpoint TLS requirements with strict Suite B curve restrictions.
#
# Reference: STIG rule WN11-CC-000195 / V-253363, TLS cipher suite configuration.
# AVD TLS requirements: https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint

# $LgpoTxtFile is defined here and passed to every Update-LocalGPOTextFile call
# (-OutputFile) AND to lgpo.exe /t below — one variable, no convention mismatch.
$LgpoTxtFile = Join-Path -Path $Script:LGPOTempDir -ChildPath 'AVD-Exceptions.txt'

Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002' -RegistryValue 'EccCurves' -Delete -OutputFile $LgpoTxtFile

# Edge proxy (breaks AVD connectivity when set by the STIG GPO)
Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Edge' -RegistryValue 'ProxySettings' -Delete -OutputFile $LgpoTxtFile

If (-not $IsDomainJoined) {
    # Remove firewall and CAD settings that break non-domain-joined Remote Desktop.
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Windows' -RegistryValue 'DisableCAD' -RegistryData '0' -RegistryType 'DWORD' -OutputFile $LgpoTxtFile
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -OutputFile $LgpoTxtFile
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PrivateProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -OutputFile $LgpoTxtFile
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -OutputFile $LgpoTxtFile
}

# Apply registry policy overrides built above
Write-Log -Message "Applying AVD Exceptions registry overrides via lgpo.exe /t"
$r = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/t `"$LgpoTxtFile`"" -Wait -PassThru
Write-Log -Message "lgpo.exe /t exited with code [$($r.ExitCode)]"
$GPUpdate = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -Wait -PassThru
Write-Log -Message "'gpupdate.exe' exited with code [$($GPUpdate.ExitCode)])."

# V-253289 MEDIUM: The Secondary Logon service must be disabled on Windows 11.
Write-Log -Message "V-253289: Disabling the Secondary Logon Service."
$Service = 'SecLogon'
$Serviceobject = Get-Service | Where-Object { $_.Name -eq $Service }
If ($Serviceobject) {
    $StartType = $ServiceObject.StartType
    If ($StartType -ne 'Disabled') {
        Set-RegistryValue -Name Start -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\seclogon' -PropertyType DWORD -Value 4
    }
    If ($ServiceObject.Status -ne 'Stopped') {
        Try {
            Stop-Service $Service -Force
        }
        Catch {
        }
    }
}

# V-257592 MEDIUM: Windows 11 must not have portproxy enabled or in use.
$output = cmd /c netsh interface portproxy show all '2>&1'
If ($output) {
    Write-Log -Message "V-257592: Disabling PortProxy rules."
    Start-Process -FilePatch 'netsh.exe' -ArgumentList 'interface portproxy delete' -Wait -NoNewWindow
}

# V-253396 MEDIUM: Explorer Data Execution Prevention must be enabled.
# This is enforced via the DoD STIG GPO (NoDataExecutionPrevention registry value must
# not be set to 1).  The GPO package applied above via lgpo.exe handles this control.
# NOTE: The old STIG rule WIN11-00-000145 previously required 'bcdedit /set nx OptOut'
# (OS-level DEP boot configuration).  That rule was REMOVED in V2R7 and there is no
# equivalent bcdedit requirement in the current STIG.  No bcdedit action is needed here.

# ── Windows Optional Features (V-253275, V-253276, V-253277, V-253278, V-253279, V-253286) ────────────
# V-253275 HIGH: IIS must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'IIS-WebServer'         -StigId 'V-253275'
Disable-OptionalFeatureIfEnabled -FeatureName 'IIS-HostableWebCore'   -StigId 'V-253275'

# V-253276 MEDIUM: SNMP must not be installed
# SNMP ships as a Windows Capability on Windows 11; also check legacy optional feature name
$snmpCap = Get-WindowsCapability -Online -Name 'SNMP.Client~~~~0.0.1.0' -ErrorAction SilentlyContinue
if ($snmpCap -and $snmpCap.State -eq 'Installed') {
    Write-Log -Message 'V-253276: Removing SNMP Client Windows Capability.'
    Remove-WindowsCapability -Online -Name 'SNMP.Client~~~~0.0.1.0' -ErrorAction SilentlyContinue | Out-Null
} else {
    Write-Log -Message 'V-253276: SNMP Client capability not installed. No action required.'
}
Disable-OptionalFeatureIfEnabled -FeatureName 'SNMP'        -StigId 'V-253276'

# V-253277 MEDIUM: Simple TCP/IP Services must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'SimpleTCP'   -StigId 'V-253277'

# V-253278 MEDIUM: Telnet Client must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'TelnetClient' -StigId 'V-253278'

# V-253279 MEDIUM: TFTP Client must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'TFTP'         -StigId 'V-253279'

# V-253286 MEDIUM: SMB v1 protocol must be disabled
Disable-OptionalFeatureIfEnabled -FeatureName 'SMB1Protocol' -StigId 'V-253286'

# WN11-00-000125 / V-268317 - Remove Microsoft Copilot
# IMAGE BUILD: Remove-AppxProvisionedPackage removes the package from the image so it is not
# provisioned for any user created from this image.  Remove-AppxPackage covers any profiles
# that already exist on the build VM (e.g., the build administrator account).
Write-Log -Message 'V-268317: Removing Microsoft Copilot provisioned package (image build).'
Get-AppxProvisionedPackage -Online |
    Where-Object { $_.DisplayName -like '*Copilot*' } |
    ForEach-Object {
        Write-Log -Message "  Removing provisioned package: $($_.DisplayName)"
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
Get-AppxPackage -AllUsers |
    Where-Object { $_.Name -like '*Copilot*' } |
    ForEach-Object {
        Write-Log -Message "  Removing user package: $($_.Name)"
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }

# V-253359 MEDIUM: Run as different user must be removed from context menus.
Write-Log -Message "V-253359: Removing Run As User from context menus."
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\batfile\shell\runasuser' -PropertyType DWORD -Value 4096
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\cmdfile\shell\runasuser' -PropertyType DWORD -Value 4096
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\exefile\shell\runasuser' -PropertyType DWORD -Value 4096
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\mscfile\shell\runasuser' -PropertyType DWORD -Value 4096

# V-253340 / V-253341 / V-253342 - Event log permissions
# Restrict Application, Security, and System event log access so non-privileged accounts
# cannot read the logs.  The CustomSD registry value is read by the EventLog service on
# startup and overrides the on-disk ACL.  SDDL grants: SYSTEM Full, Administrators Full,
# Server Operators Read/Write, Interactive Users Read, Service Users Read, Batch Read,
# Write-Restricted Read, Event Log Readers (S-1-5-32-573) Read — no BUILTIN\Users entry.
$eventLogSddl = 'O:BAG:SYD:(A;;0xf0007;;;SY)(A;;0x7;;;BA)(A;;0x7;;;SO)(A;;0x3;;;IU)(A;;0x3;;;SU)(A;;0x3;;;S-1-5-3)(A;;0x3;;;S-1-5-33)(A;;0x1;;;S-1-5-32-573)'
$eventLogMap = @{
    'Application' = 'V-253340'
    'Security'    = 'V-253341'
    'System'      = 'V-253342'
}
foreach ($log in $eventLogMap.Keys) {
    $stig = $eventLogMap[$log]
    Write-Log -Message "${stig}: Setting $log event log CustomSD to restrict non-privileged access."
    Set-RegistryValue -Name 'CustomSD' `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\$log" `
        -PropertyType String `
        -Value $eventLogSddl
}

# CVE-2013-3900
Write-Log -Message "CVE-2013-3900: Mitigating PE Installation risks."
Set-RegistryValue -Name EnableCertPaddingCheck -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\WinTrust\Config' -PropertyType DWORD -Value 1
Set-RegistryValue -Name EnableCertPaddingCheck -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography\WinTrust\Config' -PropertyType DWORD -Value 1

Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue

# Stamp STIG version to registry
If ($stigVersion) {
    Write-Log -Message "Stamping STIG version to registry: $stigVersion"
    If (-not (Test-Path -Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
        Write-Log -Message "Created registry path: $registryPath"
    }
    Set-ItemProperty -Path $registryPath -Name $registryValueName -Value $stigVersion -Force
    Write-Log -Message "STIG version stamped successfully."
}
Else {
    Write-Log -Category Warning -Message "Unable to determine STIG version. Version not stamped to registry."
}

Write-Log -Message "Ending '$PSCommandPath'."

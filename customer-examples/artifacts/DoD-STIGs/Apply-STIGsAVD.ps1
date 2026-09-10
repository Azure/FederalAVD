<#
.SYNOPSIS
    This script uses the local group policy object tool (lgpo.exe) to apply the applicable DISA STIGs GPOs either downloaded directly from CyberCom or
    the files are contained with this script in the root of a folder.

.PARAMETER ApplicationsToSTIG
    This parameter defines the third party applications that should be STIGd by this script.

.PARAMETER SearchForApplications
    This parameter defines whether or not the script verifies the applications defined in 'ApplicationsToSTIG' are installed before applying the settings.

.PARAMETER AllowLocalUserLogon
    This switch parameter permits eligible local users to log on interactively and through Remote Desktop Services.

.PARAMETER STIGsUrl
    This parameter defines the URL of the STIG GPOs ZIP file to be downloaded and applied.

.PARAMETER Upgrade
    This parameter indicates that the script will compare each applicable STIG version with its registry stamp and reset local group policy before applying the STIGs if any version has changed.

.NOTES
    To use this script offline, download the lgpo tool from 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' and store it in the root of the folder where the script is located.'
    to the root of the folder where this script is located. Then download the latest STIG GPOs ZIP from 'https://public.cyber.mil/stigs/gpo' and it to the root
    of the folder where this script is located.

    This script not only applies the GPO objects but it also applies some registry settings and other mitigations. Ensure that these other items still apply through the
    lifecycle of the script.
#>
[CmdletBinding()]
param (
    [string[]]$ApplicationsToSTIG = @('Adobe Acrobat Pro','Adobe Acrobat Reader','Google Chrome','Mozilla Firefox'),
    
    [switch]$SearchForApplications,

    [string]$STIGsUrl = 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_July_2026.zip',

    [switch]$Upgrade,

    [switch]$AllowLocalUserLogon
)
#region Initialization
$Script:Name = 'Apply-STIGs'
[string]$LGPOUrl = 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip'
$osCaption = (Get-WmiObject -Class Win32_OperatingSystem).caption
If ($osCaption -match 'Windows 11') {
    $osVersion = 11
}
ElseIf ($osCaption -match 'Windows 10') {
    $osVersion = 10
}
Else {
    throw "Unsupported operating system '$osCaption'. This artifact supports Windows 10 and Windows 11 only."
}
[string]$Script:TempDir = Join-Path -Path "$env:SystemRoot\Temp" -ChildPath $Script:Name
[string]$Script:LGPOTempDir = Join-Path -Path $Script:TempDir -ChildPath 'LGPO'

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
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 
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

Function Set-ExistingPrivilegeRight {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string[]]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$Principals
    )

    $setting = "$Name = $($Principals -join ',')"
    $matchingIndexes = @()
    For ($index = 0; $index -lt $Content.Count; $index++) {
        If ($Content[$index] -match "^\s*$([regex]::Escape($Name))\s*=") {
            $matchingIndexes += $index
        }
    }

    If ($matchingIndexes.Count -gt 1) {
        throw "Security template contains multiple '$Name' assignments."
    }
    If ($matchingIndexes.Count -eq 1) {
        $Content[$matchingIndexes[0]] = $setting
    }
    return $Content
}

Function Remove-PrivilegeRightPrincipals {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string[]]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$Principals
    )

    return $Content | ForEach-Object {
        If ($_ -match "^\s*$([regex]::Escape($Name))\s*=\s*(?<Values>.*)$") {
            $remainingPrincipals = @($matches.Values -split ',' | ForEach-Object { $_.Trim() } | Where-Object {
                $_ -and $_ -notin $Principals
            })
            "$Name = $($remainingPrincipals -join ',')"
        }
        Else {
            $_
        }
    }
}

Function Update-PrivilegeRightPlaceholders {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string[]]$Content,
        [Parameter(Mandatory = $true)]
        [bool]$DomainJoined
    )

    $placeholderReplacements = @{
        'ADD YOUR ENTERPRISE ADMINS' = If ($DomainJoined) { 'Enterprise Admins' } Else { $null }
        'ADD YOUR DOMAIN ADMINS'     = If ($DomainJoined) { 'Domain Admins' } Else { $null }
    }

    return $Content | ForEach-Object {
        If ($_ -match '^(?<Prefix>\s*[^=]+\s*=\s*)(?<Values>.*)$') {
            $prefix = $matches.Prefix
            $principals = @($matches.Values -split ',' | ForEach-Object { $_.Trim() })
            $updatedPrincipals = @($principals | ForEach-Object {
                If ($placeholderReplacements.ContainsKey($_)) {
                    $replacement = $placeholderReplacements[$_]
                    If ($null -ne $replacement) { $replacement }
                }
                ElseIf ($_) {
                    $_
                }
            })
            "$prefix$($updatedPrincipals -join ',')"
        }
        Else {
            $_
        }
    }
}

Function Get-StigVersionMap {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string[]]$FolderName
    )

    $versions = @{}
    ForEach ($name in $FolderName) {
        If ($name -notmatch '^(?<StigName>.+?)\s+(?<StigVersion>[vV]\d+[rR]\d+)$') {
            throw "Unable to determine the STIG name and version from folder '$name'. Expected a name ending in v<major>r<revision>."
        }

        $stigName = $matches.StigName.Trim()
        $stigVersion = $matches.StigVersion.ToLowerInvariant()
        If ($versions.ContainsKey($stigName) -and $versions[$stigName] -ne $stigVersion) {
            throw "Multiple versions of '$stigName' are applicable: '$($versions[$stigName])' and '$stigVersion'."
        }
        $versions[$stigName] = $stigVersion
    }
    return $versions
}

Function Update-LocalGPOTextFile {
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
    If ($Delete) { Add-Content -Path $OutputFile -Value 'DELETE' }
    ElseIf ($DeleteAllValues) { Add-Content -Path $OutputFile -Value 'DELETEALLVALUES' }
    Else { Add-Content -Path $OutputFile -Value "$($ValueType):$RegistryData" }
    Add-Content -Path $OutputFile -Value ''
}

Function New-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [string] $Path = (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
    )

    if ($env:SUPPRESS_FILELOG -eq '1') { return }
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
            # /target:computer limits processing to Machine-side policy only. During image
            # build there is no real user session; running a full gpupdate causes the User-side
            # Registry CSE to attempt to write STIG settings into HKCU paths that do not exist
            # in the build context, producing Event 8194 / 0x80070003. User-side policies in
            # GroupPolicy\User\Registry.pol are applied correctly when users log into deployed
            # session hosts.
            Write-Log -message "${CmdletName}: Forcing machine policy refresh (gpupdate /force /target:computer)..."
            $gp = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c gpupdate /force /target:computer' -Wait -PassThru
            if ($gp.ExitCode -ne 0) {
                Write-Log -Category Warning -Message "${CmdletName}: gpupdate returned non-zero exit code: $($gp.ExitCode)"
            }
        }
        else {
            Write-Log -Message "${CmdletName}: Skipping gpupdate. (A reboot will also reapply policies.)"
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
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][string]$StigId
    )
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -eq 'Enabled') {
        Write-Log -Message "${StigId}: Disabling Windows Optional Feature '$FeatureName'."
        Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop | Out-Null
    }
    else {
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

    $Content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content $Script:Log $Content -ErrorAction SilentlyContinue
    }
    Switch ($Category) {
        'Info' { Write-Host $Content }
        'Error' { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}
#endregion

#region Main

New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
Write-Log -Message "Starting '$PSCommandPath'."
$ErrorActionPreference = 'Stop'

Try {
If (Test-Path -LiteralPath $Script:TempDir) {
    Write-Log -Message "Removing stale temporary content from '$Script:TempDir'."
    Remove-Item -LiteralPath $Script:TempDir -Recurse -Force -ErrorAction Stop
}
$null = New-Item -Path $Script:LGPOTempDir -ItemType Directory -Force -ErrorAction Stop

$registryPath = 'HKLM:\Software\DoD\STIG'

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
    $fileLGPO = (Get-ChildItem -Path $Script:TempDir -Filter 'lgpo.exe' -Recurse | Select-Object -First 1).FullName
    Write-Log -Message "Copying '$fileLGPO' to '$env:SystemRoot\system32'."
    Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -Force
}
$stigZips = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.zip' | Where-Object { $_.Name -notmatch 'LGPO.zip' } | Sort-Object LastWriteTime -Descending)
$stigZip = $stigZips | Select-Object -First 1
If ($stigZip) {
    If ($stigZips.Count -gt 1) {
        Write-Log -Category Warning -Message "Multiple STIG ZIP files found in '$PSScriptRoot'. Using the newest: '$($stigZip.Name)'. Remove older packages to avoid ambiguity."
    }
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

$ApplicableFolders = @($ApplicableFolders | Sort-Object -Property FullName -Unique)

Write-Log -Message "Found $($ApplicableFolders.Count) applicable GPO folders:"
$ApplicableFolders | ForEach-Object { Write-Log -Message "  $_" } 
[array]$GPOFolders = @()
ForEach ($folder in $ApplicableFolders) {
    $gpoFolderPaths = @(Get-ChildItem -Path $folder.FullName -Filter 'GPOs' -Directory)
    If ($gpoFolderPaths.Count -ne 1) {
        throw "Expected one GPOs directory under '$($folder.FullName)', found $($gpoFolderPaths.Count)."
    }
    $GPOFolders += $gpoFolderPaths[0].FullName
}
$applicableStigVersions = Get-StigVersionMap -FolderName @($ApplicableFolders.Name)
$applicableStigVersions.GetEnumerator() | Sort-Object -Property Name | ForEach-Object {
    Write-Log -Message "Applicable STIG version: $($_.Name) = $($_.Value)"
}

If ($Upgrade) {
    Write-Log -Message 'Upgrade mode enabled. Comparing each applicable STIG with its registry stamp.'
    $needsReset = $false
    ForEach ($stigName in $applicableStigVersions.Keys) {
        $desiredVersion = $applicableStigVersions[$stigName]
        $existingVersion = Get-ItemPropertyValue -Path $registryPath -Name $stigName -ErrorAction SilentlyContinue
        If ($existingVersion -ne $desiredVersion) {
            $displayExistingVersion = If ($null -eq $existingVersion) { '<not stamped>' } Else { $existingVersion }
            Write-Log -Message "STIG version mismatch for '$stigName'. Applied: $displayExistingVersion, Package: $desiredVersion. Policy reset will be performed."
            $needsReset = $true
        }
    }

    If ($needsReset) {
        Write-Log -Message 'Resetting Local Group Policy before applying the applicable STIGs.'
        Try {
            Reset-LocalPolicy -ResetSecurity -Verbose
            Write-Log -Message 'Local Group Policy reset completed successfully.'
        }
        Catch {
            throw "Error resetting Local Group Policy: $($_.Exception.Message)"
        }
    }
    Else {
        Write-Log -Message 'All applicable STIG registry versions match the package. No policy reset needed.'
    }
}

# Capture any pre-existing Edge/Chrome proxy config before the STIG GPO import below
# overwrites it, so it can be restored afterward instead of unconditionally deleted.
$Script:PreExistingEdgeProxySettings = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'ProxySettings' -ErrorAction SilentlyContinue
$Script:PreExistingChromeProxySettings = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'ProxySettings' -ErrorAction SilentlyContinue

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
        $Content = Get-Content -Path $SecEditFile -Encoding Unicode
        Write-Output "Applying AVD exceptions to DoD Windows $osVersion security template: $SecEditFile"

        # Remove administrator account disable/rename lines
        Write-Log -Message "[GptTmpl] Removing 'NewAdministratorName' and 'EnableAdminAccount' - Azure manages the built-in administrator account (RID-500) independently; allowing the STIG to rename or disable it breaks local admin access and agent operations."
        $Content | Where-Object { ($_ -like 'NewAdministratorName*') -or ($_ -like 'EnableAdminAccount*') } |
        ForEach-Object { Write-Output "  [GptTmpl] REMOVED : $_" }
        $Content = $Content | Where-Object { (-not ($_ -like 'NewAdministratorName*')) -and (-not ($_ -like 'EnableAdminAccount*')) }

        # Replace or remove the exact domain-group placeholder principals that the DoD STIG GPO
        # leaves in the [Privilege Rights] section. Process each assignment once so logging and
        # persisted content use the same transformation.
        $placeholderRightsBefore = @($Content | Where-Object { $_ -match 'ADD YOUR ENTERPRISE ADMINS|ADD YOUR DOMAIN ADMINS' })
        If ($IsDomainJoined) {
            Write-Log -Message "[GptTmpl] Replacing domain administrator placeholders with actual group names - required for privilege right assignments to function correctly on domain-joined AVD session hosts."
        }
        Else {
            Write-Log -Message "[GptTmpl] Removing domain administrator placeholders - these domain group principals are not applicable on non-domain-joined AVD session hosts."
        }
        $Content = @(Update-PrivilegeRightPlaceholders -Content $Content -DomainJoined $IsDomainJoined)
        ForEach ($beforePlaceholderRight in $placeholderRightsBefore) {
            $rightName = ($beforePlaceholderRight -split '=', 2)[0].Trim()
            $afterPlaceholderRight = $Content | Where-Object { $_ -match "^\s*$([regex]::Escape($rightName))\s*=" }
            Write-Output "  [GptTmpl] BEFORE  : $beforePlaceholderRight"
            Write-Output "  [GptTmpl] AFTER   : $afterPlaceholderRight"
        }

        # If the STIG defines SeRemoteInteractiveLogonRight, set it to RDS Users (S-1-5-32-555)
        # and Administrators (S-1-5-32-544). Do not create user-right assignments omitted by the STIG.
        $beforeRemoteInteractiveLogonRight = $Content | Where-Object { $_ -like 'SeRemoteInteractiveLogonRight*' }
        If ($beforeRemoteInteractiveLogonRight) {
            $Content = Set-ExistingPrivilegeRight -Content $Content -Name 'SeRemoteInteractiveLogonRight' -Principals @('*S-1-5-32-555', '*S-1-5-32-544')
            $afterRemoteInteractiveLogonRight = $Content | Where-Object { $_ -like 'SeRemoteInteractiveLogonRight*' }
            Write-Log -Message "[GptTmpl] Setting STIG-defined 'SeRemoteInteractiveLogonRight' (Allow log on through Remote Desktop Services) to Remote Desktop Users (S-1-5-32-555) and Administrators (S-1-5-32-544)."
            Write-Output "  [GptTmpl] BEFORE  : $beforeRemoteInteractiveLogonRight"
            Write-Output "  [GptTmpl] AFTER   : $afterRemoteInteractiveLogonRight"
        }
        Else {
            Write-Log -Message "[GptTmpl] The STIG does not define 'SeRemoteInteractiveLogonRight'; leaving the existing system user-right assignment unchanged."
        }
       
        if ($AllowLocalUserLogon) {
            # Adjust only user-right assignments defined by the STIG. Remove both Local account deny
            # SIDs from interactive and RDS deny rights because deny rights override allow rights.
            If ($Content | Where-Object { $_ -like 'SeInteractiveLogonRight*' }) {
                $Content = Set-ExistingPrivilegeRight -Content $Content -Name 'SeInteractiveLogonRight' -Principals @('*S-1-5-32-545', '*S-1-5-32-544')
            }
            $localAccountDenySids = @('*S-1-5-113', '*S-1-5-114')
            ForEach ($denyRight in @('SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight')) {
                $beforeDenyRight = $Content | Where-Object { $_ -like "$denyRight*" }
                $Content = Remove-PrivilegeRightPrincipals -Content $Content -Name $denyRight -Principals $localAccountDenySids
                $afterDenyRight = $Content | Where-Object { $_ -like "$denyRight*" }
                Write-Log -Message "[GptTmpl] Updating '$denyRight': Removing Local account deny SIDs S-1-5-113 and S-1-5-114 - AllowLocalUserLogon is enabled. Guests and all other deny principals remain."
                Write-Output "  [GptTmpl] BEFORE  : $beforeDenyRight"
                Write-Output "  [GptTmpl] AFTER   : $afterDenyRight"
            }
        }
        Set-Content -Path $SecEditFile -Value $Content -Encoding Unicode
    }

    Write-Log -Message "Running 'LGPO.exe /g `"$gpoFolder`"'"
    $lgpo = Start-Process -FilePath "$env:SystemRoot\System32\lgpo.exe" -ArgumentList "/g `"$gpoFolder`"" -Wait -PassThru
    if ($lgpo.ExitCode -ne 0) {
        throw "lgpo.exe /g failed with exit code [$($lgpo.ExitCode)] for folder '$gpoFolder'."
    }
    else {
        Write-Log -Message "'lgpo.exe' exited with code [$($lgpo.ExitCode)]."
    }
}

Write-Log -Message "Applying AVD Administrative Template-based Exceptions"
# $LgpoTxtFile is defined here and passed to every Update-LocalGPOTextFile call
# (-OutputFile) AND to lgpo.exe /t below - one variable, no convention mismatch.
$LgpoTxtFile = Join-Path -Path $Script:LGPOTempDir -ChildPath 'AVD-Exceptions.txt'

if ($null -ne $Script:PreExistingEdgeProxySettings) {
    Write-Log -Message "[AdminTemplate] Restoring pre-existing 'ProxySettings' under HKLM\SOFTWARE\Policies\Microsoft\Edge - the STIG GPO import overwrote it with its own placeholder proxy that blocks AVD gateway and broker connectivity, but a value was already present before the STIG ran, so it is restored rather than deleted."
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Edge' -RegistryValue 'ProxySettings' -RegistryType 'String' -RegistryData $Script:PreExistingEdgeProxySettings -OutputFile $LgpoTxtFile
} else {
    Write-Log -Message "[AdminTemplate] Deleting 'ProxySettings' from HKLM\SOFTWARE\Policies\Microsoft\Edge - the STIG GPO configures an Edge proxy that blocks AVD gateway and broker connectivity. No pre-existing value was present before the STIG GPO import, so deleting allows Edge to use system proxy settings or direct connections."
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Edge' -RegistryValue 'ProxySettings' -Delete -OutputFile $LgpoTxtFile
}

if ($null -ne $Script:PreExistingChromeProxySettings) {
    Write-Log -Message "[AdminTemplate] Restoring pre-existing 'ProxySettings' under HKLM\SOFTWARE\Policies\Google\Chrome - the DISA Google Chrome STIG configures a proxy that blocks AVD gateway and broker connectivity, but a value was already present before the STIG ran, so it is restored rather than deleted."
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Google\Chrome' -RegistryValue 'ProxySettings' -RegistryType 'String' -RegistryData $Script:PreExistingChromeProxySettings -OutputFile $LgpoTxtFile
} else {
    Write-Log -Message "[AdminTemplate] Deleting 'ProxySettings' from HKLM\SOFTWARE\Policies\Google\Chrome - the DISA Google Chrome STIG configures a proxy that blocks AVD gateway and broker connectivity. No pre-existing value was present before the STIG GPO import, so deleting allows Chrome to use system proxy settings or direct connections."
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Google\Chrome' -RegistryValue 'ProxySettings' -Delete -OutputFile $LgpoTxtFile
}

# V-253260 - BitLocker startup PIN requirement (UseAdvancedStartup, UseTPMPIN, UseTPMKeyPIN)
# The STIG mandates BitLocker startup authentication with a PIN or PIN+key.
# Per the finding: "For AVD implementations with no data at rest, this is NA."
# AVD session hosts are stateless - the OS disk contains no persistent user data and is
# typically refreshed or deleted on logoff. Enforcing a BitLocker startup PIN on an AVD
# session host would prevent the VM from booting unattended after reboot (e.g. after
# Windows Update or a scale event), breaking the session host lifecycle entirely.
Write-Log -Message "[AdminTemplate] Deleting 'UseAdvancedStartup' (V-253260) from HKLM\SOFTWARE\Policies\Microsoft\FVE - BitLocker advanced startup is NA for AVD (stateless session hosts have no data at rest). Enforcing a startup PIN prevents unattended VM boot after reboots triggered by Windows Update or scale events."
Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\FVE' -RegistryValue 'UseAdvancedStartup' -Delete -OutputFile $LgpoTxtFile
Write-Log -Message "[AdminTemplate] Deleting 'UseTPMPIN' (V-253260) from HKLM\SOFTWARE\Policies\Microsoft\FVE - BitLocker TPM+PIN startup is NA for AVD session hosts. See UseAdvancedStartup above."
Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\FVE' -RegistryValue 'UseTPMPIN' -Delete -OutputFile $LgpoTxtFile
Write-Log -Message "[AdminTemplate] Deleting 'UseTPMKeyPIN' (V-253260) from HKLM\SOFTWARE\Policies\Microsoft\FVE - BitLocker TPM+key+PIN startup is NA for AVD session hosts. See UseAdvancedStartup above."
Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\FVE' -RegistryValue 'UseTPMKeyPIN' -Delete -OutputFile $LgpoTxtFile

If (-not $IsDomainJoined) {
    # Remove firewall settings that break non-domain-joined Remote Desktop.
    Write-Log -Message "[AdminTemplate] Deleting 'AllowLocalPolicyMerge' from DomainProfile, PrivateProfile, and PublicProfile firewall policies - the STIG blocks local firewall rule merging; on non-domain-joined AVD session hosts this prevents local firewall rules (including AVD agent rules) from being applied alongside GPO rules."
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -OutputFile $LgpoTxtFile
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PrivateProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -OutputFile $LgpoTxtFile
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -OutputFile $LgpoTxtFile
}

# M365 Apps STIG - Privacy / Trust Center (User Configuration > Administrative Templates >
# Microsoft Office 2016 > Privacy > Trust Center)
# The STIG GPO package available for download from cyber.mil does not yet include the
# M365 Apps STIG v3r5, which removed these four settings. If an older GPO package is
# applied, these values may be written to policy. These Delete entries are a
# belt-and-suspenders measure to ensure settings that DISA has already validated should
# not be applied are cleared out regardless of which package version was downloaded.
Write-Log -Message "[AdminTemplate] Deleting 'disconnectedstate' from User\Software\Policies\Microsoft\Office\16.0\Common\Privacy - removes the M365 STIG setting for 'Allow the use of connected experiences in Office' so it reverts to Not Configured."
Update-LocalGPOTextFile -Scope 'User' -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Common\Privacy' -RegistryValue 'disconnectedstate' -Delete -OutputFile $LgpoTxtFile
Write-Log -Message "[AdminTemplate] Deleting 'usercontentdisabled' from User\Software\Policies\Microsoft\Office\16.0\Common\Privacy - removes the M365 STIG setting for 'Allow the use of connected experiences in Office that analyze content' so it reverts to Not Configured."
Update-LocalGPOTextFile -Scope 'User' -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Common\Privacy' -RegistryValue 'usercontentdisabled' -Delete -OutputFile $LgpoTxtFile
Write-Log -Message "[AdminTemplate] Deleting 'downloadcontentdisabled' from User\Software\Policies\Microsoft\Office\16.0\Common\Privacy - removes the M365 STIG setting for 'Allow the use of connected experiences in Office that download online content' so it reverts to Not Configured."
Update-LocalGPOTextFile -Scope 'User' -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Common\Privacy' -RegistryValue 'downloadcontentdisabled' -Delete -OutputFile $LgpoTxtFile
Write-Log -Message "[AdminTemplate] Deleting 'controllerconnectedservicesenabled' from User\Software\Policies\Microsoft\Office\16.0\Common\Privacy - removes the M365 STIG setting for 'Allow the use of additional optional connected experiences in Office' so it reverts to Not Configured."
Update-LocalGPOTextFile -Scope 'User' -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Common\Privacy' -RegistryValue 'controllerconnectedservicesenabled' -Delete -OutputFile $LgpoTxtFile

# Apply registry policy overrides built above
Write-Log -Message "Applying AVD Exceptions registry overrides via lgpo.exe /t"
$r = Start-Process -FilePath "$env:SystemRoot\System32\lgpo.exe" -ArgumentList "/t `"$LgpoTxtFile`"" -Wait -PassThru
Write-Log -Message "lgpo.exe /t exited with code [$($r.ExitCode)]"
if ($r.ExitCode -ne 0) {
    throw "lgpo.exe /t failed with exit code [$($r.ExitCode)]."
}
# /target:computer - same reasoning as above: no real user session during image build.
$GPUpdate = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force /target:computer' -Wait -PassThru
Write-Log -Message "'gpupdate.exe' exited with code [$($GPUpdate.ExitCode)])."
if ($GPUpdate.ExitCode -ne 0) {
    throw "gpupdate.exe failed with exit code [$($GPUpdate.ExitCode)]."
}

# V-253289 MEDIUM: The Secondary Logon service must be disabled on Windows 11.
Write-Log -Message "V-253289: Disabling the Secondary Logon Service."
$Service = 'SecLogon'
$Serviceobject = Get-Service | Where-Object { $_.Name -eq $Service }
If ($Serviceobject) {
    $StartType = $ServiceObject.StartType
    If ($StartType -ne 'Disabled') {
        Set-RegistryValue -Name Start -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\seclogon' -PropertyType DWORD -Value 4
    }
    If ($ServiceObject.Status -ne 'Stopped') { Stop-Service $Service -Force -ErrorAction Stop }
}

# V-257592 MEDIUM: Windows 11 must not have portproxy enabled or in use.
Write-Log -Message "V-257592: Resetting all PortProxy rules."
$netsh = Start-Process -FilePath 'netsh.exe' -ArgumentList 'interface portproxy reset' -Wait -PassThru -NoNewWindow
if ($netsh.ExitCode -ne 0) {
    throw "netsh.exe failed to reset PortProxy rules with exit code [$($netsh.ExitCode)]."
}

# V-253396 MEDIUM: Explorer Data Execution Prevention must be enabled.
# This is enforced via the DoD STIG GPO (NoDataExecutionPrevention registry value must
# not be set to 1).  The GPO package applied above via lgpo.exe handles this control.
# NOTE: The old STIG rule WIN11-00-000145 previously required 'bcdedit /set nx OptOut'
# (OS-level DEP boot configuration).  That rule was REMOVED in V2R7 and there is no
# equivalent bcdedit requirement in the current STIG.  No bcdedit action is needed here.

# -- Windows Optional Features (V-253275, V-253276, V-253277, V-253278, V-253279, V-253285, V-253286) ----
# V-253275 HIGH: IIS must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'IIS-WebServer'         -StigId 'V-253275'
Disable-OptionalFeatureIfEnabled -FeatureName 'IIS-HostableWebCore'   -StigId 'V-253275'

# V-253276 MEDIUM: SNMP must not be installed
# SNMP ships as a Windows Capability on Windows 11; also check legacy optional feature name
$snmpCap = Get-WindowsCapability -Online -Name 'SNMP.Client~~~~0.0.1.0' -ErrorAction SilentlyContinue
if ($snmpCap -and $snmpCap.State -eq 'Installed') {
    Write-Log -Message 'V-253276: Removing SNMP Client Windows Capability.'
    Remove-WindowsCapability -Online -Name 'SNMP.Client~~~~0.0.1.0' -ErrorAction Stop | Out-Null
}
else {
    Write-Log -Message 'V-253276: SNMP Client capability not installed. No action required.'
}
Disable-OptionalFeatureIfEnabled -FeatureName 'SNMP'        -StigId 'V-253276'

# V-253277 MEDIUM: Simple TCP/IP Services must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'SimpleTCP'   -StigId 'V-253277'

# V-253278 MEDIUM: Telnet Client must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'TelnetClient' -StigId 'V-253278'

# V-253279 MEDIUM: TFTP Client must not be installed
Disable-OptionalFeatureIfEnabled -FeatureName 'TFTP'         -StigId 'V-253279'

# V-253285 MEDIUM: Windows PowerShell 2.0 must be disabled.
# The finding is NA on Windows 11 24H2 and newer, where the features are normally absent.
# Checking both feature names also protects older supported Windows 10/11 image versions.
Disable-OptionalFeatureIfEnabled -FeatureName 'MicrosoftWindowsPowerShellV2Root' -StigId 'V-253285'
Disable-OptionalFeatureIfEnabled -FeatureName 'MicrosoftWindowsPowerShellV2'     -StigId 'V-253285'

# V-253286 MEDIUM: SMB v1 protocol must be disabled
Disable-OptionalFeatureIfEnabled -FeatureName 'SMB1Protocol' -StigId 'V-253286'

# V-288475 MEDIUM: All Wi-Fi Direct adapters must be disabled.
# This finding was added in the Windows 11 STIG v2r9 after the July 2026 v2r8 GPO package.
$wifiDirectAdapters = @(Get-NetAdapter -InterfaceDescription 'Microsoft Wi-Fi Direct*' -IncludeHidden -ErrorAction SilentlyContinue)
if ($wifiDirectAdapters.Count -gt 0) {
    Write-Log -Message "V-288475: Disabling $($wifiDirectAdapters.Count) Wi-Fi Direct adapter(s)."
    $wifiDirectAdapters | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
}
else {
    Write-Log -Message 'V-288475: No Wi-Fi Direct adapters found. No action required.'
}

# WN11-00-000125 / V-268317 - Remove Microsoft Copilot
# IMAGE BUILD: Remove-AppxProvisionedPackage removes the package from the image so it is not
# provisioned for any user created from this image.  Remove-AppxPackage covers any profiles
# that already exist on the build VM (e.g., the build administrator account).
Write-Log -Message 'V-268317: Removing Microsoft Copilot provisioned package (image build).'
Get-AppxProvisionedPackage -Online |
Where-Object { $_.DisplayName -like '*Copilot*' } |
ForEach-Object {
    Write-Log -Message "  Removing provisioned package: $($_.DisplayName)"
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
}
Get-AppxPackage -AllUsers |
Where-Object { $_.Name -like '*Copilot*' } |
ForEach-Object {
    Write-Log -Message "  Removing user package: $($_.Name)"
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
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
# Write-Restricted Read, Event Log Readers (S-1-5-32-573) Read - no BUILTIN\Users entry.
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

# Stamp each successfully applied STIG with its own release version.
If (-not (Test-Path -Path $registryPath)) {
    New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
    Write-Log -Message "Created registry path: $registryPath"
}
ForEach ($stigName in ($applicableStigVersions.Keys | Sort-Object)) {
    $appliedVersion = $applicableStigVersions[$stigName]
    New-ItemProperty -Path $registryPath -Name $stigName -PropertyType String -Value $appliedVersion -Force -ErrorAction Stop | Out-Null
    Write-Log -Message "Stamped applied STIG version: $stigName = $appliedVersion"
}
# Remove the legacy package-level stamp after individual STIG stamps succeed.
Remove-ItemProperty -Path $registryPath -Name 'Version' -ErrorAction SilentlyContinue


# Strip obsolete/missing CSE GUIDs from gPCUserExtensionNames in gpt.ini.
# LGPO adds these GUIDs when processing IE Administrative Templates, but the
# handler DLLs (ieaksie.dll for {B087BE9D}, no handler for {00000000}) do not
# exist on Windows 10/11. Their presence causes a "file not found" error in
# gpresult when the GP client re-evaluates the incremented version after deployment.
# The IE registry values themselves are already captured in User\Registry.pol by
# the {35378EAC} Registry CSE entry, so removing these entries is safe.
$gptPath = "$env:SystemRoot\System32\GroupPolicy\gpt.ini"
if (Test-Path $gptPath) {
    $gptContent = Get-Content $gptPath -Raw
    $original = $gptContent
    # Remove the IEM CSE ({B087BE9D}) and null-GUID ({00000000}) user extension pairs
    $gptContent = $gptContent -replace '\[\{B087BE9D-ED37-454F-AF9C-04291E351182\}\{[^}]+\}\]', ''
    $gptContent = $gptContent -replace '\[\{00000000-0000-0000-0000-000000000000\}\{[^}]+\}\]', ''
    if ($gptContent -ne $original) {
        [IO.File]::WriteAllText($gptPath, $gptContent, [System.Text.Encoding]::ASCII)
        Write-Log -Message "gpt.ini: stripped obsolete IEM and null-GUID CSE entries from gPCUserExtensionNames."
    }
    else {
        Write-Log -Message "gpt.ini: no obsolete CSE GUIDs found - no changes made."
    }
}

Write-Log -Message "Ending '$PSCommandPath'."
}
Finally {
    If (Test-Path -LiteralPath $Script:TempDir) {
        Write-Log -Message "Removing temporary content from '$Script:TempDir'."
        Remove-Item -LiteralPath $Script:TempDir -Recurse -Force -ErrorAction Stop
    }
}

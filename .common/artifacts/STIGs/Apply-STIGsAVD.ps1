<#
.SYNOPSIS
    This script uses the local group policy object tool (lgpo.exe) to apply the applicable DISA STIGs GPOs either downloaded directly from CyberCom or
    the files are contained with this script in the root of a folder.
.PARAMETER ApplicationsToSTIG
    This parameter defines the third party applications that should be STIGd by this script. This needs to be defined as a JSON string to support Run Commands.
.NOTES
    To use this script offline, download the lgpo tool from 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' and store it in the root of the folder where the script is located.'
    to the root of the folder where this script is located. Then download the latest STIG GPOs ZIP from 'https://public.cyber.mil/stigs/gpo' and and save at at STIGs.zip in the root
    of the folder where this script is located.

    This script not only applies the GPO objects but it also applies some registry settings and other mitigations. Ensure that these other items still apply through the
    lifecycle of the script.

#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$ApplicationsToSTIG = '["Adobe Acrobat Pro", "Adobe Acrobat Reader", "Google Chrome", "Mozilla Firefox"]'
)
#region Initialization
$Script:Name = 'Apply-STIGs'
$osCaption = (Get-WmiObject -Class Win32_OperatingSystem).caption
If ($osCaption -match 'Windows 11') { $osVersion = 11 } Else { $osVersion = 10 }
$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $Script:Name
If (Test-Path -Path $Script:TempDir) { Remove-Item -Path $Script:TempDir -Recurse -ErrorAction SilentlyContinue }
New-Item -Path $Script:TempDir -ItemType Directory -Force | Out-Null
#endregion

#region Functions

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
            If ($SensitiveValues) { Write-Log -message "Array '$Name' has $($Array.Length) members" } Else { Write-Log -message "$($Name): '$($Array -join "', '")'" }
            Return $Array
        }
        Else {
            Return $null
        }            
    }
    Else {
        Return $null
    }    
}

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
                                SearchString       = $name
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

Function Get-InternetUrl {
    [CmdletBinding()]
    Param (
        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the website that contains a link to the desired download."
        )]
        [uri]$WebSiteUrl,

        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the search string. Wildcard '*' can be used."    
        )]
        [string]$SearchString
    )

    $HTML = Invoke-WebRequest -Uri $WebSiteUrl -UseBasicParsing
    $Links = $HTML.Links
    #First try to find search string in actual link href
    $LinkHref = $HTML.Links.Href | Get-Unique | Where-Object { $_ -like "*$SearchString*" }
    If ($LinkHref) {
        Return $LinkHref
    }
    #If not found, try to find search string in the outer html
    $LinkHrefs = $Links | Where-Object { $_.OuterHTML -like "*$SearchString*" }
    If ($LinkHrefs) {
        Return $LinkHrefs.href
    }
    Else {
        $Pattern = '"url":\s*"(https://[^"]*?' + $SearchString.Replace('.', '\.').Replace('*', '.*').Replace('+', '\+') + ')"' 
        If ($HTML.Content -match $Pattern) {
            If ($matches[1].Contains('"')) {
                Return $matches[1].Substring(0, $matches[1].IndexOf('"'))
            }
            Else {
                Return $matches[1]
            }

        }
        else {
            Write-Log -Category Error -Message "No download URL found using search term."
            Return $null
        }
    }

}

Function Invoke-LGPO {
    [CmdletBinding()]
    Param (
        [string]$InputDir = $Script:TempDir,
        [string]$SearchTerm
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Message "${CmdletName}: Gathering Registry text files for LGPO from '$InputDir'"
        Write-Log -Message "${CmdletName}: Gathering Security Templates files for LGPO from '$InputDir'"
        [array]$RegistryFiles = @()
        [array]$SecurityTemplates = @()
        If ($SearchTerm) {
            $RegistryFiles = Get-ChildItem -Path $InputDir -Filter "$SearchTerm*.txt"
            $SecurityTemplates = Get-ChildItem -Path $InputDir -Filter "$SearchTerm*.inf"
        }
        Else {
            $RegistryFiles = Get-ChildItem -Path $InputDir -Filter "*.txt"
            $SecurityTemplates = Get-ChildItem -Path $InputDir -Filter '*.inf'
        }
        ForEach ($RegistryFile in $RegistryFiles) {
            $TxtFilePath = $RegistryFile.FullName
            Write-Log -Message "${CmdletName}: Now applying settings from '$txtFilePath' to Local Group Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/t `"$TxtFilePath`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
        ForEach ($SecurityTemplate in $SecurityTemplates) {        
            $SecurityTemplate = $SecurityTemplate.FullName
            Write-Log -Message "${CmdletName}: Now applying security settings from '$SecurityTemplate' to Local Security Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/s `"$SecurityTemplate`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
    }
    End {
    }
}

function New-Log {
    <#
    .SYNOPSIS
    Sets default log file and stores in a script accessible variable $script:Log
    Log File name "packageExecution_$date.log"

    .PARAMETER Path
    Path to the log file

    .EXAMPLE
    New-Log c:\Windows\Logs
    Create a new log file in c:\Windows\Logs
    #>

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

function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )

    $Date = get-date
    $Content = "[$Date]`t$Category`t`t$Message`n" 
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

Function Update-LocalGPOTextFile {
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    Param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Delete')]
        [Parameter(Mandatory = $true, ParameterSetName = 'DeleteAllValues')]
        [string]$OutFilePrefix,
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
        [string]$outputDir = $Script:TempDir
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        # Convert $RegistryType to UpperCase to prevent LGPO errors.
        $ValueType = $RegistryType.ToUpper()
        # Change String type to SZ for text file
        If ($ValueType -eq 'STRING') { $ValueType = 'SZ' }
        # Replace any incorrect registry entries for the format needed by text file.
        $modified = $false
        $SearchStrings = 'HKLM:\', 'HKCU:\', 'HKEY_CURRENT_USER:\', 'HKEY_LOCAL_MACHINE:\'
        ForEach ($String in $SearchStrings) {
            If ($RegistryKeyPath.StartsWith("$String") -and $modified -ne $true) {
                $index = $String.Length
                $RegistryKeyPath = $RegistryKeyPath.Substring($index, $RegistryKeyPath.Length - $index)
                $modified = $true
            }
        }        
        #Create the output file if needed.
        $Outfile = "$OutputDir\$Outfileprefix-$Scope.txt"
        If (-not (Test-Path -LiteralPath $Outfile)) {
            If (-not (Test-Path -LiteralPath $OutputDir -PathType 'Container')) {
                Try {
                    $null = New-Item -Path $OutputDir -Type 'Directory' -Force -ErrorAction 'Stop'
                }
                Catch {}
            }
            $null = New-Item -Path $outputdir -Name "$OutFilePrefix-$Scope.txt" -ItemType File -ErrorAction Stop
        }

        Write-Log -Message "${CmdletName}: Adding registry information to '$outfile' for LGPO.exe"
        # Update file with information
        Add-Content -Path $Outfile -Value $Scope
        Add-Content -Path $Outfile -Value $RegistryKeyPath
        Add-Content -Path $Outfile -Value $RegistryValue
        If ($Delete) {
            Add-Content -Path $Outfile -Value 'DELETE'
        }
        ElseIf ($DeleteAllValues) {
            Add-Content -Path $Outfile -Value 'DELETEALLVALUES'
        }
        Else {
            Add-Content -Path $Outfile -Value "$($ValueType):$RegistryData"
        }
        Add-Content -Path $Outfile -Value ""
    }
    End {        
    }
}

#endregion

#region Main

New-Log
Write-Log -Message "Starting '$PSCommandPath'."
[array]$AppsToSTIG = ConvertFrom-JsonString -JsonString $ApplicationsToSTIG -Name 'AppsToSTIG'

Write-Log -message "Checking for 'lgpo.exe' in '$env:SystemRoot\system32'."

If (-not(Test-Path -Path "$env:SystemRoot\System32\lgpo.exe")) {
    Write-Log -category Info -message "'lgpo.exe' not found in '$env:SystemRoot\system32'."
    $LGPOZip = Join-Path -Path $PSScriptRoot -ChildPath 'LGPO.zip'
    If (-not(Test-Path -Path $LGPOZip)) {
        Write-Log -category Info -Message "Downloading LGPO tool."
        $LGPOZip = Get-InternetFile -Url 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' -OutputDirectory $Script:TempDir -Verbose    
    }
    Write-Log -Category Info -Message "Expanding '$LGPOZip' to '$Script:TempDir'."
    Expand-Archive -Path $LGPOZip -DestinationPath $Script:TempDir -Force
    $fileLGPO = (Get-ChildItem -Path $Script:TempDir -Filter 'lgpo.exe' -Recurse)[0].FullName
    Write-Log -Message "Copying '$fileLGPO' to '$env:SystemRoot\system32'."
    Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -Force
}

$stigZip = Join-Path -Path $PSScriptRoot -ChildPath 'STIGs.zip'
If (-not (Test-Path -Path $stigZip)) {
    $stigZip = $null
    #Download the STIG GPOs
    $uriSTIGs = 'https://public.cyber.mil/stigs/gpo'
    $uriGPODownload = Get-InternetUrl -WebSiteUrl $uriSTIGs -searchstring 'GPOs'
    If ($null -eq $uriGPODownload) { Write-Log -Category Error -Message "Unable to find download link for STIG GPOs. Exiting script."; Exit 1 }
    Write-Log -Message "Downloading STIG GPOs from '$uriGPODownload'."
    If ($uriGPODownload) {
        $stigZip = Get-InternetFile -url $uriGPODownload -OutputDirectory $Script:TempDir -Verbose
    }
    If ($null -eq $stigZip) { Write-Log -Category Error -Message "Unable to download STIG GPOs. Exiting script."; Exit 1 }
} 

Expand-Archive -Path $stigZip -DestinationPath $Script:TempDir -Force
Write-Log -Message "Copying ADMX and ADML files to local system."

$null = Get-ChildItem -Path $Script:TempDir -File -Recurse -Filter '*.admx' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
$null = Get-ChildItem -Path $Script:TempDir -Directory -Recurse | Where-Object { $_.Name -eq 'en-us' } | Get-ChildItem -File -recurse -filter '*.adml' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }

Write-Log -Message "Getting List of Applicable GPO folders."

$GPOFolders = Get-ChildItem -Path $Script:TempDir -Directory
[array]$ApplicableFolders = $GPOFolders | Where-Object { $_.Name -like "DoD*Windows $osVersion*" -or $_.Name -like 'DoD*Edge*' -or $_.Name -like 'DoD*Firewall*' -or $_.Name -like 'DoD*Internet Explorer*' -or $_.Name -like 'DoD*Defender Antivirus*' } 
If (Get-InstalledApplication -Name 'Microsoft 365', 'Office', 'Teams') {
    $ApplicableFolders += $GPOFolders | Where-Object { $_.Name -match 'M365' } 
}
$InstalledAppsToSTIG = (Get-InstalledApplication -Name $AppsToSTIG).SearchString
ForEach ($SearchString in $InstalledAppsToSTIG) {
    $ApplicableFolders += $GPOFolders | Where-Object { $_.Name -match "$SearchString" }
}
[array]$GPOFolders = @()
ForEach ($folder in $ApplicableFolders.FullName) {
    $gpoFolderPath = (Get-ChildItem -Path $folder -Filter 'GPOs' -Directory).FullName
    $GPOFolders += $gpoFolderPath
}
ForEach ($gpoFolder in $GPOFolders) {
    If ($gpoFolder -like "DoD*Windows $osVersion*") {
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
        $filteredLines = $Content | Where-Object {-not ($_ -match "^NewAdministratorName") -and -not ($_ -match "^EnableAdminAccount") }
        Set-Content -Path $SecEditFile -Value $filteredLines
    }
}
Write-Log -Message "Running 'LGPO.exe /g `"$gpoFolder`"'"
$lgpo = Start-Process -FilePath "$env:SystemRoot\System32\lgpo.exe" -ArgumentList "/g `"$gpoFolder`"" -Wait -PassThru
Write-Log -Message "'lgpo.exe' exited with code [$($lgpo.ExitCode)]."

Write-Log -Message "Applying AVD Exceptions"
$OutputFilePrefix = 'AVD-Exceptions'
$SecFileContent = @'
[Unicode]
Unicode=yes
[Version]
signature="$CHICAGO$"
Revision=1
[Registry Values]
MACHINE\SYSTEM\CurrentControlSet\Control\Lsa\Pku2u\AllowOnlineID=4,1
[Privilege Rights]
SeRemoteInteractiveLogonRight = *S-1-5-32-555,*S-1-5-32-544
SeDenyBatchLogonRight = *S-1-5-32-546
SeDenyNetworkLogonRight = *S-1-5-32-546
SeDenyInteractiveLogonRight = *S-1-5-32-546
SeDenyRemoteInteractiveLogonRight = *S-1-5-32-546
'@
# Applying AVD Exceptions
$SecTemplate = Join-Path -Path $Script:TempDir -ChildPath "$OutputFilePrefix.inf"
$SecFileContent | Out-File -FilePath $SecTemplate -Encoding unicode
# Remove Setting that breaks AVD
Update-LocalGPOTextFile -outfileprefix $OutputFilePrefix -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002' -RegistryValue 'EccCurves' -Delete -Verbose
# Remove Firewall Configuration that breaks stand-alone workstation Remote Desktop.
Update-LocalGPOTextFile -outfileprefix $OutputFilePrefix -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -Verbose
Update-LocalGPOTextFile -outfileprefix $OutputFilePrefix -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PrivateProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -Verbose
Update-LocalGPOTextFile -outfileprefix $OutputFilePrefix -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile' -RegistryValue 'AllowLocalPolicyMerge' -Delete -Verbose
# Remove Edge Proxy Configuration
Update-LocalGPOTextFile -outfileprefix $OutputFilePrefix -Scope 'Computer' -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\Edge' -RegistryValue 'ProxySettings' -Delete -Verbose
Invoke-LGPO -SearchTerm $OutputFilePrefix

#Disable Secondary Logon Service
#WN10-00-000175
Write-Log -Message "WN10-00-000175/V-220732: Disabling the Secondary Logon Service."
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

Write-Log -Message "Configuring Registry Keys that aren't policy objects."
# WN10-CC-000039
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\batfile\shell\runasuser' -PropertyType DWORD -Value 4096
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\cmdfile\shell\runasuser' -PropertyType DWORD -Value 4096
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\exefile\shell\runasuser' -PropertyType DWORD -Value 4096
Set-RegistryValue -Name SuppressionPolicy -Path 'HKLM:\SOFTWARE\Classes\mscfile\shell\runasuser' -PropertyType DWORD -Value 4096

# CVE-2013-3900
Write-Log -Message "CVE-2013-3900: Mitigating PE Installation risks."
Set-RegistryValue -Name EnableCertPaddingCheck -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\WinTrust\Config' -PropertyType DWORD -Value 1
Set-RegistryValue -Name EnableCertPaddingCheck -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography\WinTrust\Config' -PropertyType DWORD -Value 1

Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Log -Message "Ending '$PSCommandPath'."
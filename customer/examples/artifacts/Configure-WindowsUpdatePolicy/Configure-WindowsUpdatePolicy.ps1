[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [ValidateSet("True", "False")]
    [string]$DisableUpdates = "False",

    [ValidateSet("0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30")]
    [string]$DeferQualityUpdatesPeriodInDays = "0",

    [ValidateSet("EveryDay", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")]
    [string]$ScheduledInstallDay = "EveryDay",

    [ValidateSet("Automatic", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23")]
    [string]$ScheduledInstallTime = "Automatic"
)

#region Functions

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
        Write-Log -Message "Starting ${CmdletName}"
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
        [string]$outputDir = (Join-Path -Path $Script:TempDir -ChildPath 'LGPO')
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
        $OutFile = Join-Path -Path $OutputDir -ChildPath "$Scope.txt"
        If (-not (Test-Path -LiteralPath $Outfile)) {
            If (-not (Test-Path -LiteralPath $OutputDir -PathType 'Container')) {
                $null = New-Item -Path $OutputDir -Type 'Directory' -Force -ErrorAction 'Stop'
            }
            $null = New-Item -Path $OutFile -ItemType File -ErrorAction Stop
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

Function Invoke-LGPO {
    [CmdletBinding()]
    Param (
        [string]$InputDir = $Script:LGPOTempDir
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Message "${CmdletName}: Gathering Registry text files for LGPO from '$InputDir'"
        $RegFiles = Get-ChildItem -Path $InputDir -Filter '*.txt'
        ForEach ($RegistryFile in $RegFiles) {
            $TxtFilePath = $RegistryFile.FullName
            Write-Log -Message "${CmdletName}: Now applying settings from '$txtFilePath' to Local Group Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/t `"$TxtFilePath`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
        Write-Log -Message "${CmdletName}: Gathering Security Templates files for LGPO from '$InputDir'"
        $ConfigFile = Get-ChildItem -Path $InputDir -Filter '*.inf'
        If ($ConfigFile) {
            $ConfigFile = $ConfigFile.FullName
            Write-Log -Message "${CmdletName}: Now applying security settings from '$ConfigFile' to Local Security Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/s `"$ConfigFile`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
        Write-Log -Message "${CmdletName}: Finding Audit CSV file for LGPO from '$InputDir'"
        $AuditFile = Get-ChildItem -Path $InputDir -Filter '*.csv'
        If ($AuditFile) {
            $AuditFile = $AuditFile.FullName
            Write-Log -Message "${CmdletName}: Now applying advanced audit settings from '$AuditFile' to Local policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/ac `"$AuditFile`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
    }
    End {
    }
}

function Remove-RegistryValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        try {
            Write-Log -Message "${CmdletName}: Deleting registry value '$Name' from '$Path' if it exists."
            if (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop) {
                Remove-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
                Write-Log -Message "${CmdletName}: Deleted registry value '$Name' from '$Path'."
            }
        }
        catch {
            # Silently continue if the value doesn't exist
            Write-Log -Message "${CmdletName}: Registry value '$Name' not found at '$Path'. Nothing to delete."
        }
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
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
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Message "${CmdletName}: Setting Registry Value $Path\$Name"
        # Create the registry Key(s) if necessary.
        If (!(Test-Path -Path $Path)) {
            Write-Log -Message "${CmdletName}: Creating Registry Key: $Path"
            New-Item -Path $Path -Force | Out-Null
        }
        # Check for existing registry setting
        $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($RemoteValue) {
            # Get current Value
            $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
            Write-Log -Message "${CmdletName}: Current Value of $($Path)\$($Name) : $CurrentValue"
            If ($Value -ne $CurrentValue) {
                Write-Log -Message "${CmdletName}: Setting Value of $($Path)\$($Name) : $Value"
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            }
            Else {
                Write-Log -Message "${CmdletName}: Value of $($Path)\$($Name) is already set to $Value"
            }           
        }
        Else {
            Write-Log -Message "${CmdletName}: Setting Value of $($Path)\$($Name) : $Value"
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
    }
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

function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
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
#endregion Functions

#region Initialization
if ($DisableUpdates.ToLower() -eq 'true') {
    [bool]$DisableUpdates = $true
}
Else {
    [bool]$DisableUpdates = $false
}
[int]$DeferQualityUpdatesPeriodInDays = $DeferQualityUpdatesPeriodInDays
Switch ($ScheduledInstallDay) {
    "Sunday" { [int]$ScheduledInstallDay = 1 }
    "Monday" { [int]$ScheduledInstallDay = 2 }
    "Tuesday" { [int]$ScheduledInstallDay = 3 }
    "Wednesday" { [int]$ScheduledInstallDay = 4 }
    "Thursday" { [int]$ScheduledInstallDay = 5 }
    "Friday" { [int]$ScheduledInstallDay = 6 }
    "Saturday" { [int]$ScheduledInstallDay = 7 }
    default { [int]$ScheduledInstallDay = 0 }
}
Switch ($ScheduledInstallTime) {
    "Automatic" { [int]$ScheduledInstallTime = 24 }
    default { [int]$ScheduledInstallTime = $ScheduledInstallTime }
}
[string]$Script:Name = "Configure-WindowsUpdatePolicy"
[string]$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $ScriptName
[string]$Script:LGPOTempDir = Join-Path -Path $Script:TempDir -ChildPath 'LGPO'
If (-not(Test-Path -Path $Script:LGPOTempDir)) { New-Item -Path $Script:LGPOTempDir -ItemType Directory -Force | Out-Null }
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
Write-Log -Category Info -Message "Parameters: DeferQualityUpdatesPeriodInDays='$DeferQualityUpdatesPeriodInDays', ScheduledInstallDay='$ScheduledInstallDay', ScheduledInstallTime='$ScheduledInstallTime'."
#endregion

Write-Log -message "Checking for 'lgpo.exe' in '$env:SystemRoot\system32'."

If (-not(Test-Path -Path "$env:SystemRoot\System32\lgpo.exe")) {
    Write-Log -Category Info -Message "'lgpo.exe' not found in '$env:SystemRoot\system32'."
    $LGPOZip = Get-ChildItem -Path $PSScriptRoot -Filter 'LGPO.zip' -Recurse | Select-Object -First 1
    If (-not($LGPOZip)) {
        Write-Log -Category Info -Message "Downloading LGPO tool."
        $LGPOZip = Get-InternetFile -Url 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' -OutputDirectory $Script:TempDir -Verbose
    }    
    If ($LGPOZip) {
        Write-Log -Category Info -Message "Expanding '$LGPOZip' to '$Script:TempDir'."
        Expand-Archive -Path $LGPOZip -DestinationPath $Script:TempDir -Force
        $fileLGPO = (Get-ChildItem -Path $Script:TempDir -Filter 'lgpo.exe' -Recurse)[0].FullName
        Write-Log -Message "Copying '$fileLGPO' to '$env:SystemRoot\system32'."
        Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -Force
    }
}

If (Test-Path -Path "$env:SystemRoot\System32\Lgpo.exe") {
    if ($DisableUpdates -eq $true) {
        $regKey = "Software\Policies\Microsoft\Windows\WindowsUpdate\AU"
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'NoAutoUpdate' -RegistryType 'DWORD' -RegistryData 1 -Verbose
    }
    Else {
        $regKey = "Software\Policies\Microsoft\Windows\WindowsUpdate"
        
        Write-Log -category info -message "Now Configuring Windows Update Settings via LGPO."
        If ($DeferQualityUpdatesPeriodInDays -ge 1 -and $DeferQualityUpdatesPeriodInDays -le 30) {
            Write-Log -Category Info -Message "Setting DeferQualityUpdatesPeriodInDays to '$DeferQualityUpdatesPeriodInDays'."
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'DeferQualityUpdates' -RegistryType 'DWORD' -RegistryData 1 -Verbose
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'DeferQualityUpdatesPeriodInDays' -RegistryType 'DWORD' -RegistryData $DeferQualityUpdatesPeriodInDays -Verbose
        }
        Else {
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'DeferQualityUpdates' -Delete -Verbose
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'DeferQualityUpdatesPeriodInDays' -Delete -Verbose
        }    
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'SetComplianceDeadline' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ConfigureDeadlineForFeatureUpdates' -RegistryType 'DWORD' -RegistryData 7 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ConfigureDeadlineGracePeriodForFeatureUpdates' -RegistryType 'DWORD' -RegistryData 2 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ConfigureDeadlineNoAutoReboot' -Delete -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'SetComplianceDeadlineForQU' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ConfigureDeadlineForQualityUpdates' -RegistryType 'DWORD' -RegistryData 3 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ConfigureDeadlineGracePeriod' -RegistryType 'DWORD' -RegistryData 2 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ConfigureDeadlineNoAutoRebootForQualityUpdates' -Delete -Verbose 
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'SetUpdateNotificationLevel' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'UpdateNotificationLevel' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'NoUpdateNotificationDuringActiveHours' -RegistryType DWORD -RegistryData 1 -Verbose
    
        $regKey = "Software\Policies\Microsoft\Windows\WindowsUpdate\AU"

        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'AllowMUUpdateService' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'AUOptions' -RegistryType 'DWORD' -RegistryData 4 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'NoAutoUpdate' -RegistryType 'DWORD' -RegistryData 0 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'IncludeRecommendedUpdates' -Delete -Verbose
        Write-Log -Category Info -Message "Setting ScheduledInstallDay to '$ScheduledInstallDay'."
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallDay' -RegistryType 'DWORD' -RegistryData $ScheduledInstallDay -Verbose    
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallTime' -RegistryType 'DWORD' -RegistryData $ScheduledInstallTime -Verbose
        If ($ScheduledInstallTime -eq 24) {
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'AutomaticMaintenanceEnabled' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        }   
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallEveryWeek' -RegistryType 'DWORD' -RegistryData 1 -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallFirstWeek' -Delete -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallSecondWeek' -Delete -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallThirdWeek' -Delete -Verbose
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath $regKey -RegistryValue 'ScheduledInstallFourthWeek' -Delete -Verbose    
    }
    Invoke-LGPO -Verbose
    Write-Log -category Info -message "Windows Update Settings Configured."
    $gpupdate = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -Wait -PassThru
    Write-Log -Message "GPUpdate exitcode: '$($gpupdate.exitcode)'"
}
Else {
    Write-Log -Category Warning -Message "Unable to configure local policy with lgpo tool because it was not found. Updating registry settings instead."
    if ($DisableUpdates -eq $true) {
        $regKey = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"    
        Set-RegistryValue -Path $regKey -Name 'NoAutoUpdate' -PropertyType 'DWord' -Value 1
    }
    Else {
        $regKey = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"

        If ($DeferQualityUpdatesPeriodInDays -ge 1 -and $DeferQualityUpdatesPeriodInDays -le 30) {
            Write-Log -Category Info -Message "Setting DeferQualityUpdatesPeriodInDays to '$DeferQualityUpdatesPeriodInDays'."
            Set-RegistryValue -Path $regKey -Name 'DeferQualityUpdates' -PropertyType 'DWord' -Value 1
            Set-RegistryValue -Path $regKey -Name 'DeferQualityUpdatesPeriodInDays' -PropertyType 'DWord' -Value $DeferQualityUpdatesPeriodInDays
        }
        Else {
            Remove-RegistryValue -Path $regKey -Name 'DeferQualityUpdates'
            Remove-RegistryValue -Path $regKey -Name 'DeferQualityUpdatesPeriodInDays'
        }
        Set-RegistryValue -Path $regKey -Name 'SetComplianceDeadline' -PropertyType 'DWord' -Value 1
        Set-RegistryValue -Path $regKey -Name 'ConfigureDeadlineForFeatureUpdates' -PropertyType 'DWord' -Value 7
        Set-RegistryValue -Path $regKey -Name 'ConfigureDeadlineGracePeriodForFeatureUpdates' -PropertyType 'DWord' -Value 2
        Remove-RegistryValue -Path $regKey -Name 'ConfigureDeadlineNoAutoReboot'
        Set-RegistryValue -Path $regKey -Name 'SetComplianceDeadlineForQU' -PropertyType 'DWord' -Value 1
        Set-RegistryValue -Path $regKey -Name 'ConfigureDeadlineForQualityUpdates' -PropertyType 'DWord' -Value 3
        Set-RegistryValue -Path $regKey -Name 'ConfigureDeadlineGracePeriod' -PropertyType 'DWord' -Value 2
        Remove-RegistryValue -Path $regKey -Name 'ConfigureDeadlineNoAutoRebootForQualityUpdates'
        Set-RegistryValue -Path $regKey -Name 'SetUpdateNotificationLevel' -PropertyType 'DWord' -Value 1
        Set-RegistryValue -Path $regKey -Name 'UpdateNotificationLevel' -PropertyType 'DWord' -Value 1
        Set-RegistryValue -Path $regKey -Name 'NoUpdateNotificationDuringActiveHours' -PropertyType 'DWord' -Value 1

        $regKey = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"

        Set-RegistryValue -Path $regKey -Name 'AllowMUUpdateService' -PropertyType 'DWord' -Value 1
        Set-RegistryValue -Path $regKey -Name 'AUOptions' -PropertyType 'DWord' -Value 4
        Set-RegistryValue -Path $regKey -Name 'NoAutoUpdate' -PropertyType 'DWord' -Value 0
        Remove-RegistryValue -Path $regKey -Name 'IncludeRecommendedUpdates'
        Set-RegistryValue -Path $regKey -Name 'ScheduledInstallDay' -PropertyType 'DWord' -Value $ScheduledInstallDay
        Set-RegistryValue -Path $regKey -Name 'ScheduledInstallTime' -PropertyType 'DWord' -Value $ScheduledInstallTime
        If ($ScheduledInstallTime -eq 24) {
            Set-RegistryValue -Path $regKey -Name 'AutomaticMaintenanceEnabled' -PropertyType 'DWord' -Value 1
        }
        Set-RegistryValue -Path $regKey -Name 'ScheduledInstallEveryWeek' -PropertyType 'DWord' -Value 1
        Remove-RegistryValue -Path $regKey -Name 'ScheduledInstallFirstWeek'
        Remove-RegistryValue -Path $regKey -Name 'ScheduledInstallSecondWeek'
        Remove-RegistryValue -Path $regKey -Name 'ScheduledInstallThirdWeek'
        Remove-RegistryValue -Path $regKey -Name 'ScheduledInstallFourthWeek'
    }
}
Write-Log -category Info -message "Completed configuring Windows Update Settings."

Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
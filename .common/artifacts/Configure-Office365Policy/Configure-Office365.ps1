[CmdletBinding(SupportsShouldProcess = $true)]
param (

    [Parameter(Mandatory = $false)]
    [boolean]$DisableUpdates,

    [ValidateSet("Not Configured", "3 days", "1 week", "2 weeks", "1 month", "3 months", "6 months", "12 months", "24 months", "36 months", "60 months", "All")]
    [string]$EmailCacheTime = "1 month",

    # Outlook Calendar Sync Mode, Microsoft Recommendation is Primary Calendar Only. See https://support.microsoft.com/en-us/help/2768656/outlook-performance-issues-when-there-are-too-many-items-or-folders-in
    [ValidateSet("Not Configured", "Inactive", "Primary Calendar Only", "All Calendar Folders")]
    [string]$CalendarSync = "Primary Calendar Only",

    # Outlook Calendar Sync Months, Microsoft Recommendation is 1 Month. See https://support.microsoft.com/en-us/help/2768656/outlook-performance-issues-when-there-are-too-many-items-or-folders-in
    [ValidateSet("Not Configured", "1", "3", "6", "12")]
    [string]$CalendarSyncMonths = "1"
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
    #First try to find search string in actual link href
    $Links = $HTML.Links
    $LinkHref = $HTML
    $LinkHref = $HTML.Links.Href | Get-Unique | Where-Object { $_ -like $SearchString }
    If ($LinkHref) {
        if ($LinkHref.Contains('http://') -or $LinkHref.Contains('https://')) {
            Return $LinkHref
        }
        Else {
            $LinkHref = $WebSiteUrl.AbsoluteUri + $LinkHref
            Return $LinkHref
        }
        Return $LinkHref
    }
    #If not found, try to find search string in the outer html
    $LinkHref = $Links | Where-Object { $_.OuterHTML -like $SearchString }
    If ($LinkHref) {
        Return $LinkHref.href
    }
    # Escape user input for regex and convert * to regex wildcard
    $escapedPattern = [Regex]::Escape($SearchString) -replace '\\\*', '[^""''\s>]*'
    # Match http or https URLs ending in the desired filename pattern
    $regex = "https?://[^""'\s>]*$escapedPattern"
    Return ([regex]::Matches($html.Content, $regex)).Value
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
        [ValidateSet('Computer', 'User')]
        [string]$scope,
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
        [string]$outputDir = "$Script:TempDir\LGPO",
        [string]$outfileprefix = $AppName
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

        Write-Log -message "${CmdletName}: Adding registry information to '$outfile' for LGPO.exe"
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
        [string]$InputDir = "$Script:TempDir\LGPO",
        [string]$SearchTerm
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -category Info -message "${CmdletName}: Gathering Registry text files for LGPO from '$InputDir'"
        If ($SearchTerm) {
            $InputFiles = Get-ChildItem -Path $InputDir -Filter "$SearchTerm*.txt"
        }
        Else {
            $InputFiles = Get-ChildItem -Path $InputDir -Filter '*.txt'
        }
        ForEach ($RegistryFile in $inputFiles) {
            $TxtFilePath = $RegistryFile.FullName
            Write-Log -message "${CmdletName}: Now applying settings from '$txtFilePath' to Local Group Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/t `"$TxtFilePath`"" -Wait -PassThru
            Write-Log -message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
    }
    End {
    }
}

function Write-Log {

    <#
    .SYNOPSIS
    Creates a log file and stores logs based on categories with tab seperation

    .PARAMETER category
    Category to put into the trace

    .PARAMETER message
    Message to be logged

    .EXAMPLE
    Log 'Info' 'Message'

    #>

    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $message
    )

    $date = get-date
    $content = "[$date]`t$category`t`t$message`n"
    Write-Verbose "$Script:Name $content" -verbose

    if (! $script:Log) {
        $File = Join-Path $env:TEMP -ChildPath "$Script:Name.log"
        Write-Warning "Log file not found, create new $File"
        $script:Log = $File
    }
    else {
        $File = $script:Log
    }
    Add-Content $File $content -ErrorAction Stop
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
[string]$AppName = 'Office365'
[string]$Script:Name = "Configure-Office365Policy"
[string]$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $Script:Name
$null = New-Item -Path $Script:TempDir -ItemType Directory -Force
New-Log (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
#endregion

Write-Log -category Info -message "Running Script to Configure Microsoft Office 365 Policies and registry settings."

$O365TemplatesExe = (Get-ChildItem -Path $PSScriptRoot -Filter '*.exe').FullName
If (-not $O365TemplatesExe) {
    $WebsiteUrl = "https://www.microsoft.com/en-us/download/details.aspx?id=49030"
    $SearchString = "admintemplates_x64*.exe"
    Write-Log -Category Info -message "Downloading Office 365 Templates from '$WebsiteUrl'."
    $O365TemplatesDownloadUrl = Get-InternetUrl -WebSiteUrl $WebsiteUrl -SearchString $SearchString
    If ($O365TemplatesDownloadUrl) {
        $O365TemplatesExe = Get-InternetFile -Url $O365TemplatesDownloadUrl -OutputDirectory $Script:TempDir
    }    
}
If ($O365TemplatesExe) {
    $DirTemplates = Join-Path -Path $Script:TempDir -ChildPath 'Office365Templates'
    $null = New-Item -Path $DirTemplates -ItemType Directory
    $null = Start-Process -FilePath $O365TemplatesExe -ArgumentList "/extract:$DirTemplates /quiet" -Wait -PassThru
    Write-Log -message "Copying ADMX and ADML files to PolicyDefinitions folder."
    $null = Get-ChildItem -Path $DirTemplates -File -Recurse -Filter '*.admx' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
    $null = Get-ChildItem -Path $DirTemplates -Directory -Recurse | Where-Object { $_.Name -eq 'en-us' } | Get-ChildItem -File -recurse -filter '*.adml' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }
}

Write-Log -Message "Checking for lgpo.exe in '$env:SystemRoot\system32'."

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

If (Test-Path -Path "$env:SystemRoot\System32\lgpo.exe") {
    Write-Log -category Info -message "Now Configuring Office 365 Group Policy."
    Write-Log -Message "Update User LGPO registry text file."
    # Turn off insider notifications
    Update-LocalGPOTextFile -Scope User -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Common' -RegistryValue 'InsiderSlabBehavior' -RegistryType DWord -RegistryData 2
    
    If (($EmailCacheTime -ne 'Not Configured') -or ($CalendarSync -ne 'Not Configured') -or ($CalendarSyncMonths -ne 'Not Configured')) {
        # Enable Outlook Cached Mode
        Write-Log -Message "Configuring Outlook Cached Mode."
        Update-LocalGPOTextFile -Scope User -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -RegistryValue 'Enable' -RegistryType DWord -RegistryData 1
    }
    
    # Cached Exchange Mode Settings: https://support.microsoft.com/en-us/help/3115009/update-lets-administrators-set-additional-default-sync-slider-windows
    If ($EmailCacheTime -eq '3 days') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 3 }
    If ($EmailCacheTime -eq '1 week') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 7 }
    If ($EmailCacheTime -eq '2 weeks') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 14 }
    If ($EmailCacheTime -eq '1 month') { $SyncWindowSetting = 1 }
    If ($EmailCacheTime -eq '3 months') { $SyncWindowSetting = 3 }
    If ($EmailCacheTime -eq '6 months') { $SyncWindowSetting = 6 }
    If ($EmailCacheTime -eq '12 months') { $SyncWindowSetting = 12 }
    If ($EmailCacheTime -eq '24 months') { $SyncWindowSetting = 24 }
    If ($EmailCacheTime -eq '36 months') { $SyncWindowSetting = 36 }
    If ($EmailCacheTime -eq '60 months') { $SyncWindowSetting = 60 }
    If ($EmailCacheTime -eq 'All') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 0 }

    If ($SyncWindowSetting) {
        Update-LocalGPOTextFile -Scope User -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -RegistryValue 'SyncWindowSetting' -RegistryType DWORD -RegistryData $SyncWindowSetting
    }
    If ($SyncWindowSettingDays) {
        Update-LocalGPOTextFile -Scope User -RegistryKeyPath 'Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -RegistryValue 'SyncWindowSettingDays' -RegistryType DWORD -RegistryData $SyncWindowSettingDays
    }

    # Calendar Sync Settings: https://support.microsoft.com/en-us/help/2768656/outlook-performance-issues-when-there-are-too-many-items-or-folders-in
    If ($CalendarSync -eq 'Inactive') {
        $CalendarSyncWindowSetting = 0 
    }
    If ($CalendarSync -eq 'Primary Calendar Only') {
        $CalendarSyncWindowSetting = 1
    }
    If ($CalendarSync -eq 'All Calendar Folders') {
        $CalendarSyncWindowSetting = 2
    }

    If ($CaldendarSyncWindowSetting) {
        Reg LOAD HKLM\DefaultUser "$env:SystemDrive\Users\Default User\NtUser.dat"
        Set-RegistryValue -Path 'HKLM:\DefaultUser\Software\Policies\Microsoft\Office16.0\Outlook\Cached Mode' -Name CalendarSyncWindowSetting -Type DWord -Value $CalendarSyncWindowSetting
        If ($CalendarSyncMonths -ne 'Not Configured') {
            Set-RegistryValue -Path 'HKCU:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -Name CalendarSyncWindowSettingMonths -Type DWord -Value $CalendarSyncMonths
        }
        Write-Log -Message "Unloading default user hive."
        $null = cmd /c REG UNLOAD "HKLM\DefaultUser" '2>&1'
        If ($LastExitCode -ne 0) {
            # sometimes the registry doesn't unload properly so we have to perform powershell garbage collection first.
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 5
            $null = cmd /c REG UNLOAD "HKLM\DefaultUser" '2>&1'
            If ($LastExitCode -eq 0) {
                Write-Log -Message "Hive unloaded successfully."
            }
            Else {
                Write-Log -category Error -Message "Default User hive unloaded with exit code [$LastExitCode]."
            }
        }
        Else {
            Write-Log -Message "Hive unloaded successfully."
        }
    }

    Write-Log -Message "Update Computer LGPO registry text file."
    $RegistryKeyPath = 'SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate'
    # Hide Office Update Notifications
    Update-LocalGPOTextFile -scope Computer -RegistryKeyPath $RegistryKeyPath -RegistryValue 'HideUpdateNotifications' -RegistryType DWord -RegistryData 1
    # Hide and Disable Updates
    Update-LocalGPOTextFile -Scope Computer -RegistryKeyPath $RegistryKeyPath -RegistryValue 'HideEnableDisableUpdates' -RegistryType DWord -RegistryData 1
    If ($DisableUpdates) {
        # Disable Updates            
        Update-LocalGPOTextFile -Scope Computer -RegistryKeyPath $RegistryKeyPath -RegistryValue 'EnableAutomaticUpdates' -RegistryType DWord -RegistryData 0
    }
    Invoke-LGPO -Verbose
    Write-Log -category Info -message "Completed Configuring Office 365 Group Policy."
}
Else {
    Write-Log -Category Warning -Message "Unable to configure local policy with lgpo tool because it was not found. Updating registry settings instead."
    # Turn off insider notifications
    REG LOAD HKLM\DefaultUser "$env:SystemDrive\Users\Default User\NtUser.dat"
    Set-RegistryValue -Path 'HKLM:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Common' -Name InsiderSlabBehavior -PropertyType DWord -Value 2    
    If (($EmailCacheTime -ne 'Not Configured') -or ($CalendarSync -ne 'Not Configured') -or ($CalendarSyncMonths -ne 'Not Configured')) {
        # Enable Outlook Cached Mode
        Write-Log -Message "Configuring Outlook Cached Mode."
        Set-RegistryValue -Path 'HKLM:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -Name Enable -PropertyType DWord -Value 1
    }
    
    # Cached Exchange Mode Settings: https://support.microsoft.com/en-us/help/3115009/update-lets-administrators-set-additional-default-sync-slider-windows
    If ($EmailCacheTime -eq '3 days') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 3 }
    If ($EmailCacheTime -eq '1 week') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 7 }
    If ($EmailCacheTime -eq '2 weeks') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 14 }
    If ($EmailCacheTime -eq '1 month') { $SyncWindowSetting = 1 }
    If ($EmailCacheTime -eq '3 months') { $SyncWindowSetting = 3 }
    If ($EmailCacheTime -eq '6 months') { $SyncWindowSetting = 6 }
    If ($EmailCacheTime -eq '12 months') { $SyncWindowSetting = 12 }
    If ($EmailCacheTime -eq '24 months') { $SyncWindowSetting = 24 }
    If ($EmailCacheTime -eq '36 months') { $SyncWindowSetting = 36 }
    If ($EmailCacheTime -eq '60 months') { $SyncWindowSetting = 60 }
    If ($EmailCacheTime -eq 'All') { $SyncWindowSetting = 0; $SyncWindowSettingDays = 0 }

    If ($SyncWindowSetting) {
        Set-RegistryValue -Path 'HKLM:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -Name SyncWindowSetting -PropertyType DWord -Value $SyncWindowSetting
    }
    If ($SyncWindowSettingDays) {
        Set-RegistryValue -Path 'HKLM:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -Name SyncWindowSettingDays -PropertyType DWord -Value $SyncWindowSettingDays
    }
    # Calendar Sync Settings: https://support.microsoft.com/en-us/help/2768656/outlook-performance-issues-when-there-are-too-many-items-or-folders-in
    If ($CalendarSync -eq 'Inactive') {
        $CalendarSyncWindowSetting = 0 
    }
    If ($CalendarSync -eq 'Primary Calendar Only') {
        $CalendarSyncWindowSetting = 1
    }
    If ($CalendarSync -eq 'All Calendar Folders') {
        $CalendarSyncWindowSetting = 2
    }

    If ($CaldendarSyncWindowSetting) {
        Set-RegistryValue -Path 'HKLM:\DefaultUser\Software\Policies\Microsoft\Office16.0\Outlook\Cached Mode' -Name CalendarSyncWindowSetting -Type DWord -Value $CalendarSyncWindowSetting
        If ($CalendarSyncMonths -ne 'Not Configured') {
            Set-RegistryValue -Path 'HKCU:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode' -Name CalendarSyncWindowSettingMonths -Type DWord -Value $CalendarSyncMonths
        }        
    }
    Write-Log -Message "Unloading default user hive."
    $null = cmd /c REG UNLOAD "HKLM\DefaultUser" '2>&1'
    If ($LastExitCode -ne 0) {
        # sometimes the registry doesn't unload properly so we have to perform powershell garbage collection first.
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 5
        $null = cmd /c REG UNLOAD "HKLM\DefaultUser" '2>&1'
        If ($LastExitCode -eq 0) {
            Write-Log -Message "Hive unloaded successfully."
        }
        Else {
            Write-Log -category Error -Message "Default User hive unloaded with exit code [$LastExitCode]."
        }
    }
    Else {
        Write-Log -Message "Hive unloaded successfully."
    }
    Write-Log -Message "Update Computer LGPO registry text file."
    $RegistryKeyPath = 'SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate'
    # Hide Office Update Notifications
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -Name 'HideUpdateNotifications' -PropertyType DWord -Value 1
    # Hide and Disable Updates
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -Name 'HideEnableDisableUpdates' -PropertyType DWord -Value 1
    If ($DisableUpdates) {
        # Disable Updates
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -Name 'EnableAutomaticUpdates' -PropertyType DWord -Value 0            
    }
    Write-Log -category Info -message "Completed Configuring Office 365 Group Policy."
}

Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
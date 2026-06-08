[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [string]$AllowDeveloperTools = 'True',

    #JSON String of the SmartScreenAllowListDomains
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#smartscreenallowlistdomains
    [Parameter(Mandatory = $false)]
    [string]$SmartScreenAllowListDomains = '["portal.azure.com", "core.windows.net", "portal.azure.us", "usgovcloudapi.net"]',

    #JSON String of the PopupsAllowedForUrls
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#popupsallowedforurls
    [Parameter(Mandatory = $false)]
    [string]$PopupsAllowedForUrls = '["[*.]mil","[*.]gov","[*.]portal.azure.us","[*.]usgovcloudapi.net","[*.]azure.com","[*.]azure.net"]'
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
            $OutputFile = Join-Path $OutputDirectory -ChildPath $OutputFileName
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

Function Remove-RegistryValue {
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

Function Remove-RegistryKey {
    param (
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Message "${CmdletName}: Attempting to delete registry key '$KeyPath'."
        if (Test-Path -Path $KeyPath) {
            try {
                Remove-Item -Path $KeyPath -Recurse -Force
                Write-Log -Message "${CmdletName}: Registry key '$KeyPath' and all its contents have been deleted."
            }
            catch {
                Write-Log -Category Warning -Message "${CmdletName}: Failed to delete registry key '$KeyPath'. Error: $_"
            }
        }
        else {
            Write-Log -Message "${CmdletName}: Registry key '$KeyPath' does not exist. Nothing to delete."
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
        [string]$outputDir = $Script:LGPOTempDir
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

Function Write-Log {
    [CmdletBinding()]
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

#endregion Functions

#region Initialization
[string]$Script:Name = "Configure-EdgePolicy"
[string]$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $Script:Name
[string]$Script:LGPOTempDir = Join-Path -Path $Script:TempDir -ChildPath 'LGPO'
If (-not(Test-Path -Path $Script:LGPOTempDir)) { New-Item -Path $Script:LGPOTempDir -ItemType Directory -Force | Out-Null }

[array]$SmartScreenAllowListDomains = $SmartScreenAllowListDomains.Replace('\"', '"').Replace('\[', '[').Replace('\]', ']') | ConvertFrom-Json
[array]$PopupsAllowedForUrls = $PopupsAllowedForUrls.Replace('\"', '"').Replace('\[', '[').Replace('\]', ']') | ConvertFrom-Json
[bool]$AllowDeveloperTools = $AllowDeveloperTools.ToLower() -eq 'true'
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Configuration')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
Write-Log -Category Info -Message "Parameters: AllowDeveloperTools='$AllowDeveloperTools', SmartScreenAllowListDomains='$($SmartScreenAllowListDomains -join ',')', PopupsAllowedForUrls='$($PopupsAllowedForUrls -join ',')'."
#endregion

Write-Log -Category Info -Message "Running Script to Configure Microsoft Edge Policies."
$EdgeTemplatesCab = (Get-ChildItem -Path $PSScriptRoot -Filter '*.cab').FullName
If ($null -eq $EdgeTemplatesCab) {
    $APIUrl = "https://edgeupdates.microsoft.com/api/products?view=enterprise"
    $EdgeUpdatesJSON = Invoke-WebRequest -Uri $APIUrl -UseBasicParsing
    $content = $EdgeUpdatesJSON.content | ConvertFrom-Json      
    $Edgereleases = ($content | Where-Object { $_.Product -eq 'Stable' }).releases
    $latestrelease = $Edgereleases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } | Sort-Object ProductVersion | Select-Object -last 1
    $EdgeLatestStableVersion = $latestrelease.ProductVersion
    $policyfiles = ($content | Where-Object { $_.Product -eq 'Policy' }).releases
    $latestPolicyFile = $policyfiles | Where-Object { $_.ProductVersion -eq $EdgeLatestStableVersion }
    If (-not($latestPolicyFile)) {   
        $latestpolicyfile = $policyfiles | Sort-Object ProductVersion | Select-Object -last 1
    }  
    $EdgeTemplatesUrl = $latestpolicyfile.artifacts.Location
    If ($null -eq $EdgeTemplatesUrl) {
        Write-Log -Category Warning -Message "Unable to get download Url for Edge Policy Templates."
    }
    Else {
        Write-Log -Category Info -Message "Getting download Urls for latest Edge browser and policy templates from '$APIUrl'."
        $EdgeTemplatesCab = Get-InternetFile -Url $EdgeTemplatesUrl -OutputDirectory $Script:TempDir -Verbose
    }
}
If ($null -ne $EdgeTemplatesCab) {
    $TemplatesDir = Join-Path -Path $Script:TempDir -ChildPath 'Templates'
    New-Item -Path $TemplatesDir -ItemType Directory -Force | out-null
    Write-Log -Category Info -Message "Expanding `"$EdgeTemplatesCab`" into `"$TemplatesDir`"."
    & cmd /c extrac32 /Y /E $EdgeTemplatesCab /L "$TemplatesDir"
    $EdgeTemplatesZip = Get-ChildItem -Path "$TemplatesDir" -Filter '*.zip' -Recurse
    $EdgeTemplatesZip = $EdgeTemplatesZip[0].FullName
    Expand-Archive -Path $EdgeTemplatesZip -DestinationPath "$TemplatesDir" -force
    Write-Log -Category Info -Message "Copy ADMX and ADML files to PolicyDefinition Folders."
    $null = Get-ChildItem -Path "$TemplatesDir" -File -Recurse -Filter '*.admx' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
    $null = Get-ChildItem -Path "$TemplatesDir" -Directory -Recurse | Where-Object { $_.Name -eq 'en-us' } | Get-ChildItem -File -recurse -filter '*.adml' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }
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

If (Test-Path -Path "$env:SystemRoot\System32\Lgpo.exe") {
    Write-Log -Category Info -Message "Now Configuring Edge Group Policy."
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#hidefirstrunexperience
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'HideFirstRunExperience' -RegistryType 'DWORD' -RegistryData 1 -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#nonremovableprofileenabled
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'NonRemovableProfileEnabled' -RegistryType 'DWORD' -RegistryData 1 -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#proxysettings
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'ProxySettings' -Delete -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#automatichttpsdefault
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'AutomaticHttpsDefault' -RegistryData 0 -RegistryType DWORD -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#downloadrestrictions
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'DownloadRestrictions' -RegistryType 'DWord' -RegistryData 4 -Verbose
    if ($null -ne $SmartScreenAllowListDomains -and $SmartScreenAllowListDomains.Count -gt 0) {
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\SmartScreenAllowListDomains' -RegistryValue '*' -DeleteAllValues -Verbose
        $i = 1
        ForEach ($domain in $SmartScreenAllowListDomains) {
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\SmartScreenAllowListDomains' -RegistryValue $i -RegistryType 'STRING' -RegistryData $domain -Verbose
            $i++       
        }
    }
    if ($null -ne $PopupsAllowedForUrls -and $PopupsAllowedForUrls.Count -gt 0) {
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\PopupsAllowedForUrls' -RegistryValue '*' -DeleteAllValues -Verbose
        $i = 1
        ForEach ($url in $PopupsAllowedForUrls) {
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\PopupsAllowedForUrls' -RegistryValue $i -RegistryType 'STRING' -RegistryData $url -Verbose
            $i++
        }
    }
    if ($AllowDeveloperTools) {
        # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/developertoolsavailability
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'DeveloperToolsAvailability' -RegistryType 'DWORD' -RegistryData 1 -Verbose
    }
    Invoke-LGPO -Verbose
    $gpupdate = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -Wait -PassThru
    Write-Log -Message "GPUpdate exitcode: '$($gpupdate.exitcode)'"
}
Else {
    Write-Log -Category Warning -Message "Unable to configure local policy with lgpo tool because it was not found. Updating registry settings instead."
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#hidefirstrunexperience
    Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience' -PropertyType 'DWORD' -Value 1
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#nonremovableprofileenabled
    Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge' -Name 'NonRemovableProfileEnabled' -PropertyType 'DWORD' -Value 1
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#proxysettings
    Remove-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge' -Name 'ProxySettings'
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#automatichttpsdefault
    Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge' -Name 'AutomaticHttpsDefault' -PropertyType 'DWORD' -Value 0
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#downloadrestrictions
    Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge' -Name 'DownloadRestrictions' -PropertyType 'DWord' -Value 4
    if ($null -ne $SmartScreenAllowListDomains -and $SmartScreenAllowListDomains.Count -gt 0) {
        Remove-RegistryKey -KeyPath 'HKLM:\Software\Policies\Microsoft\Edge\SmartScreenAllowListDomains'
        $i = 1
        ForEach ($domain in $SmartScreenAllowListDomains) {
            Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge\SmartScreenAllowListDomains' -Name $i -PropertyType 'STRING' -Value $domain
            $i++       
        }
    }
    if ($null -ne $PopupsAllowedForUrls -and $PopupsAllowedForUrls.Count -gt 0) {
        Remove-RegistryKey -KeyPath 'HKLM:\Software\Policies\Microsoft\Edge\PopupsAllowedForUrls'
        $i = 1
        ForEach ($url in $PopupsAllowedForUrls) {
            Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge\PopupsAllowedForUrls' -Name $i -PropertyType 'STRING' -Value $url
            $i++
        }
    }
    If($AllowDeveloperTools) {
        # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/developertoolsavailability
        Set-RegistryValue -Path 'HKLM:\Software\Policies\Microsoft\Edge' -Name 'DeveloperToolsAvailability' -PropertyType 'DWORD' -Value 1
    }
}
Write-Log -Category Info -Message "Edge Group Policy Configuration Complete."
Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
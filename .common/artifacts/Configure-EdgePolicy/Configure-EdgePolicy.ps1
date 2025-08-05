[CmdletBinding(SupportsShouldProcess = $true)]
param (
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
        [string]$InputDir = "$TempDir\LGPO",
        [string]$SearchTerm
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    }
    Process {
        Write-Log -Category Info -Message "${CmdletName}: Gathering Registry text files for LGPO from '$InputDir'"
        If ($SearchTerm) {
            $InputFiles = Get-ChildItem -Path $InputDir -Filter "$SearchTerm*.txt"
        }
        Else {
            $InputFiles = Get-ChildItem -Path $InputDir -Filter '*.txt'
        }
        ForEach ($RegistryFile in $inputFiles) {
            $TxtFilePath = $RegistryFile.FullName
            Write-Log -Message "${CmdletName}: Now applying settings from '$txtFilePath' to Local Group Policy via LGPO.exe."
            $lgporesult = Start-Process -FilePath 'lgpo.exe' -ArgumentList "/t `"$TxtFilePath`"" -Wait -PassThru
            Write-Log -Message "${CmdletName}: LGPO exitcode: '$($lgporesult.exitcode)'"
        }
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
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
        [string]$OutputDir = "$Script:TempDir\LGPO",
        [string]$Outfileprefix = $Script:AppName
    )
    
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

Function Write-Log {
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
[String]$Script:AppName = 'Edge'
[string]$Script:Name = "Configure-EdgePolicy"
[string]$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $Script:Name
$null = New-Item -Path $Script:TempDir -ItemType Directory -Force
[array]$SmartScreenAllowListDomains = $SmartScreenAllowListDomains.Replace('\"', '"').Replace('\[', '[').Replace('\]', ']') | ConvertFrom-Json
[array]$PopupsAllowedForUrls = $PopupsAllowedForUrls.Replace('\"', '"').Replace('\[', '[').Replace('\]', ']') | ConvertFrom-Json
New-Log -Path (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
#endregion

Write-Log -Category Info -Message "Running Script to Configure Microsoft Edge Policies."
$EdgeTemplatesCab = (Get-ChildItem -Path $PSScriptRoot -Filter '*.cab').FullName
If ($EdgeTemplatesCab.Count -eq 0) {
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
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'HideFirstRunExperience' -RegistryType 'DWORD' -RegistryData 1 -outfileprefix $appName -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#nonremovableprofileenabled
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'NonRemovableProfileEnabled' -RegistryType 'DWORD' -RegistryData 1 -outfileprefix $appName -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#proxysettings
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'ProxySettings' -Delete -outfileprefix $appName -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#automatichttpsdefault
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'AutomaticHttpsDefault' -RegistryData 0 -RegistryType DWORD -outfileprefix $appName -Verbose
    # https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#downloadrestrictions
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge' -RegistryValue 'DownloadRestrictions' -RegistryType 'DWord' -RegistryData 4 -outfileprefix $appName -Verbose
    if ($null -ne $SmartScreenAllowListDomains -and $SmartScreenAllowListDomains.Count -gt 0) {
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\SmartScreenAllowListDomains' -RegistryValue '*' -DeleteAllValues -outfileprefix $appName -Verbose
        $i = 1
        ForEach ($domain in $SmartScreenAllowListDomains) {
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\SmartScreenAllowListDomains' -RegistryValue $i -RegistryType 'STRING' -RegistryData $domain -outfileprefix $appName -Verbose
            $i++       
        }
    }
    if ($null -ne $PopupsAllowedForUrls -and $PopupsAllowedForUrls.Count -gt 0) {
        Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\PopupsAllowedForUrls' -RegistryValue '*' -DeleteAllValues -outfileprefix $appName -Verbose
        $i = 1
        ForEach ($url in $PopupsAllowedForUrls) {
            Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Edge\PopupsAllowedForUrls' -RegistryValue $i -RegistryType 'STRING' -RegistryData $url -outfileprefix $appName -Verbose
            $i++
        }
    }
    Invoke-LGPO -Verbose
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
}
Write-Log -Category Info -Message "Edge Group Policy Configuration Complete."
Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
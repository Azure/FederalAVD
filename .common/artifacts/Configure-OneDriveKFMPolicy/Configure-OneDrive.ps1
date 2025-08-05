[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [string]$TenantId
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
        [string]$outfileprefix = $Script:AppName
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
        Write-Log -category Info -Message "${CmdletName}: Gathering Registry text files for LGPO from '$InputDir'"
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
[string]$Script:AppName = 'OneDrive'
[string]$Script:Name = "Configure-OneDrivePolicy"
[string]$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $ScriptName
[string]$LGPO = "$env:SystemRoot\System32\lgpo.exe"
$null = New-Item -Path $Script:TempDir -ItemType Directory -Force
New-Log -Path (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -Message "Starting '$PSCommandPath'."
#endregion
$ref = "https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders"
Write-Log -Message "Starting OneDrive configuration in accordance with '$ref'."

$InstallDir = "${env:ProgramFiles(x86)}\Microsoft OneDrive"
$OnedriveVersion = (Get-ItemProperty -Path "$installDir\onedrive.exe").VersionInfo.ProductVersion

If (Test-Path -Path "$installDir\$onedriveversion") {
    Write-Log -Message "Found OneDrive version folder '$OnedriveVersion' in '$InstallDir'."
    $null = Get-ChildItem -Path "$installDir\$onedriveversion" -File -Recurse -Filter '*.admx' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
    $ADML = (get-childitem "$InstallDir\$OneDriveVersion" -file -filter '*.adml' -recurse | Where-object { $_.Directory -like '*adm' })
    If ($null -ne $ADML) {
        ForEach ($file in $ADML) {
            $null = Copy-Item -Path $file.FullName -Destination "$env:Windir\PolicyDefinitions\en-us\" -Force
        }
    }
    Else {
        $null = Get-ChildItem -Path "$InstallDir\$OneDriveVersion" -Directory -Recurse | Where-Object { $_.Name -eq 'en-us' } | Get-ChildItem -File -recurse -filter '*.adml' | ForEach-Object { Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }
    }    
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

If (Test-Path -Path $LGPO) {
    Write-Log -Message "Now Configuring OneDrive Group Policy."
    If ($TenantID -and $TenantID -ne '') {
        Write-Log -Message "Now Configuring OneDrive to automatically sign-in with logged on user credentials."
        Update-LocalGPOTextFile -scope Computer -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\OneDrive' -RegistryValue 'SilentAccountConfig' -RegistryType DWord -RegistryData 1
        Write-Log -Message "Enabling Files on Demand"
        Update-LocalGPOTextFile -Scope Computer -RegistryKeyPath 'SOFTWARE\Policies\Microsoft\OneDrive' -RegistryValue 'FilesOnDemandEnabled' -RegistryType DWORD -RegistryData 1
        Write-Log -Message "Applying OneDrive Known Folder Move Silent Configuration Settings."
        Update-LocalGPOTextFile -Scope Computer -RegistryKeyPath "SOFTWARE\Policies\Microsoft\OneDrive" -RegistryValue 'KFMSilentOptIn' -RegistryType String -RegistryData "$TenantID"
        Update-LocalGPOTextFile -Scope Computer -RegistryKeyPath "SOFTWARE\Policies\Microsoft\OneDrive" -RegistryValue 'KFMBlockOptOut' -RegistryType DWORD -RegistryData 1
    }
    Invoke-LGPO -Verbose
    Write-Log -Message "OneDrive Group Policy Configuration Complete."
}
Else {
    Write-Log -Category Warning -Message "Unable to configure local policy with lgpo tool because it was not found. Updating registry settings instead."
    If ($TenantID -and $TenantID -ne '') {
        Write-Log -Message "Now Configuring OneDrive to automatically sign-in with logged on user credentials."
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'SilentAccountConfig' -PropertyType DWord -Value 1
        Write-Log -Message "Enabling Files on Demand"
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'FilesOnDemandEnabled' -PropertyType DWord -Value 1
        Write-Log -Message "Applying OneDrive Known Folder Move Silent Configuration Settings."
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'KFMSilentOptIn' -PropertyType String -Value "$TenantID"
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'KFMBlockOptOut' -PropertyType DWord -Value 1
    }
}

Remove-Item -Path $Script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
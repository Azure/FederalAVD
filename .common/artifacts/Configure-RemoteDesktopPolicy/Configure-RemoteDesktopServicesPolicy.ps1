[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$MaxIdleTime = '21600000',
    [string]$MaxDisconnectionTime = '21600000'
)
[int]$MaxIdleTime = $MaxIdleTime
[int]$MaxDisconnectTime = $MaxDisconnectTime

[string]$AppName = 'RDServicesPolicy'
[string]$LogDir = "$env:SystemRoot\Logs\Configuration"
[string]$ScriptName = "Configure-RemoteDesktopServicesPolicy"
[string]$Log = Join-Path -Path $LogDir -ChildPath "$ScriptName.log"
[string]$TempDir = Join-Path -Path $env:Temp -ChildPath $ScriptName
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
                $request.AllowAutoRedirect=$false
                $response=$request.GetResponse()
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
                        $OutputFileName = $contentDisposition.Split("=")[1].Replace("`"","")
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
        [string]$outputDir = "$TempDir\LGPO",
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
        [string]$InputDir = "$TempDir\LGPO",
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
        $File = Join-Path $env:TEMP "log.log"
        Write-Error "Log file not found, create new $File"
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
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
New-Log "C:\Windows\Logs\Configuration"
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
#endregion

Write-Log -message "Checking for lgpo.exe in '$env:SystemRoot\system32'."

If (-not(Test-Path -Path "$env:SystemRoot\System32\Lgpo.exe")) {
    $LGPOZip = Join-Path -Path $PSScriptRoot -ChildPath 'LGPO.zip'
    If (Test-Path -Path $LGPOZip) {
        Write-Log -Message "Expanding '$LGPOZip' to '$Script:TempDir'."
        Expand-Archive -path $LGPOZip -DestinationPath $Script:TempDir -force
        $algpoexe = Get-ChildItem -Path $Script:TempDir -filter 'lgpo.exe' -recurse
        If ($algpoexe.count -gt 0) {
            $fileLGPO = $algpoexe[0].FullName
            Write-Log -Message "Copying '$fileLGPO' to '$env:SystemRoot\system32'."
            Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -force        
        }
    } Else {
        $urlLGPO = 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip'
        $LGPOZip = Get-InternetFile -Url $urlLGPO -OutputDirectory $Script:TempDir -Verbose
        $outputDir = Join-Path $Script:TempDir -ChildPath 'LGPO'
        Expand-Archive -Path $LGPOZip -DestinationPath $outputDir
        Remove-Item $LGPOZip -Force
        $fileLGPO = (Get-ChildItem -Path $outputDir -file -Filter 'lgpo.exe' -Recurse)[0].FullName
        Write-Log -Message "Copying `"$fileLGPO`" to System32"
        Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -Force
        Remove-Item -Path $outputDir -Recurse -Force
    }
}

If (Test-Path -Path "$env:SystemRoot\System32\Lgpo.exe") {
    Write-Log -category Info -message "Now Configuring Remote Desktop Services Timeout Settings."
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Windows NT\Terminal Services' -RegistryValue 'MaxDisconnectionTime' -RegistryType 'DWORD' -RegistryData $MaxDisconnectTime -outfileprefix $appName -Verbose
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Windows NT\Terminal Services' -RegistryValue 'MaxIdleTime' -RegistryType 'DWORD' -RegistryData $MaxIdleTime -outfileprefix $appName -Verbose
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Windows NT\Terminal Services' -RegistryValue 'fResetBroken' -RegistryType 'DWORD' -RegistryData 1 -outfileprefix $appName -Verbose
    Update-LocalGPOTextFile -Scope 'Computer' -RegistryKeyPath 'Software\Policies\Microsoft\Windows NT\Terminal Services' -RegistryValue 'fEnableTimeZoneRedirection' -RegistryType 'DWORD' -RegistryData 1 -outfileprefix $appName -Verbose
    Invoke-LGPO -Verbose
}
Else {
    Write-Log -category Error -message "Unable to configure local policy with lgpo tool because it was not found."
    Exit 2
}

Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
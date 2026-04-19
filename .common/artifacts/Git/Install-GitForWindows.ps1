#region Initialization
$SoftwareName = 'GitforWindows'

#endregion

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
                Write-Log -Category Error -Message  "${CmdletName}: Error downloading file. Please check url."
                Return $Null
            }
        }
        Else {
            Write-Log -Category Error -Message  "${CmdletName}: No OutputFileName specified. Unable to download file."
            Return $Null
        }
    }
    End {
        Write-Log -Message "Ending ${CmdletName}"
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

#endregion

$SetupIni = @'
[Setup]
Lang=default
Dir=C:\Program Files\Git
Group=Git
NoIcons=0
SetupType=default
Components=ext,ext\shellhere,ext\guihere,gitlfs,assoc,assoc_sh,scalar
Tasks=
EditorOption=VisualStudioCode
CustomEditorPath=
DefaultBranchOption= 
PathOption=Cmd
SSHOption=OpenSSH
TortoiseOption=false
CURLOption=WinSSL
CRLFOption=CRLFAlways
BashTerminalOption=ConHost
GitPullBehaviorOption=Merge
UseCredentialManager=Enabled
PerformanceTweaksFSCache=Enabled
EnableSymlinks=Disabled
EnablePseudoConsoleSupport=Disabled
EnableFSMonitor=Disabled
'@

## MAIN
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
New-Log -Path (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs\Software')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

$TempDir = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\Git'
$TempDirCreated = $false

try {
    # Uninstall existing installation if present
    $Uninstaller = 'C:\Program Files\Git\unins000.exe'
    if (Test-Path -Path $Uninstaller) {
        Write-Log -Message "Git is already installed. Uninstalling."
        $uninstallProcess = Start-Process -FilePath $Uninstaller -ArgumentList '/SILENT' -Wait -PassThru -ErrorAction Stop
        if ($uninstallProcess.ExitCode -ne 0) {
            Write-Log -Category Warning -Message "Uninstaller exited with code $($uninstallProcess.ExitCode). Continuing anyway."
        }
        else {
            Write-Log -Message "Uninstall completed successfully."
        }
    }

    # Locate or download installer
    Write-Log -Message "Checking for installer in '$PSScriptRoot'."
    $installerFiles = Get-ChildItem -Path $PSScriptRoot -Filter '*.exe' -ErrorAction Stop
    if ($installerFiles.Count -gt 0) {
        $GitInstaller = $installerFiles[0].FullName
        Write-Log -Message "Found local installer: '$GitInstaller'."
    }
    else {
        Write-Log -Message "No local installer found. Retrieving latest release from GitHub API."
        New-Item -Path $TempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $TempDirCreated = $true
        $ReleasesUri = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
        Write-Log -Message "Querying '$ReleasesUri'."
        try {
            $releaseAssets = (Invoke-RestMethod -Method GET -Uri $ReleasesUri -UseBasicParsing -ErrorAction Stop).assets
        }
        catch {
            Write-Log -Category Error -Message "Failed to query GitHub API at '$ReleasesUri'. Error: $_"
            throw
        }
        $GitDownloadUrl = ($releaseAssets | Where-Object { $_.name -like '*64-bit.exe' }).browser_download_url
        if (-not $GitDownloadUrl) {
            throw "No 64-bit installer asset found in the latest Git for Windows release."
        }
        Write-Log -Message "Downloading Git installer from '$GitDownloadUrl'."
        $GitInstaller = Get-InternetFile -Url $GitDownloadUrl -OutputDirectory $TempDir
        if (-not $GitInstaller) {
            throw "Failed to download Git installer from '$GitDownloadUrl'."
        }
    }

    # Write setup INF to temp directory
    New-Item -Path $TempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $TempDirCreated = $true
    $InfPath = Join-Path $TempDir 'setup.inf'
    $SetupIni | Out-File -FilePath $InfPath -Encoding unicode -ErrorAction Stop
    Write-Log -Message "Setup INF written to '$InfPath'."

    # Install
    $ArgumentList = "/VERYSILENT /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /LOADINF=`"$InfPath`""
    Write-Log -Message "Installing '$SoftwareName' via: '$GitInstaller $ArgumentList'."
    $installerProcess = Start-Process -FilePath $GitInstaller -ArgumentList $ArgumentList -Wait -PassThru -ErrorAction Stop
    if ($installerProcess.ExitCode -eq 0) {
        Write-Log -Message "'$SoftwareName' installed successfully."
    }
    else {
        throw "'$SoftwareName' installer exited with non-zero exit code: $($installerProcess.ExitCode)."
    }

    Write-Log -Message "Completed '$SoftwareName' installation."
}
catch {
    Write-Log -Category Error -Message "Script failed: $_"
    exit 1
}
finally {
    if ($TempDirCreated -and (Test-Path -Path $TempDir)) {
        Write-Log -Message "Cleaning up temporary directory '$TempDir'."
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
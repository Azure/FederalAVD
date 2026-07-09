#region Initialization
$SoftwareName = 'GitforWindows'

#endregion

#region Functions
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
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content -ErrorAction Continue }
        'Warning' { Write-Warning $Content }
    }
}

function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path
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
    $installerFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.exe' -ErrorAction Stop | Sort-Object LastWriteTime -Descending)
    if ($installerFiles.Count -gt 0) {
        $GitInstaller = $installerFiles[0].FullName
        Write-Log -Message "Found local installer: '$GitInstaller'."
    } else {
        throw "No installer found in '$PSScriptRoot'. Please place the Git for Windows installer exe in the script directory and re-run."
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

param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'Git for Windows'

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

function Remove-GitForWindows {
    param ([int]$TimeoutMs = 600000)
    $UninstallerPath = Join-Path -Path $Env:ProgramFiles -ChildPath 'Git\unins000.exe'
    if (-not (Test-Path -LiteralPath $UninstallerPath -PathType Leaf)) {
        Write-Log -Message "'$SoftwareName' is not installed."
        return
    }
    Write-Log -Message "Removing '$SoftwareName' with '$UninstallerPath /VERYSILENT /NORESTART'."
    $process = Start-Process -FilePath $UninstallerPath -ArgumentList '/VERYSILENT /NORESTART' -PassThru -ErrorAction Stop
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "'$SoftwareName' uninstaller timed out." }
    if ($process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' uninstaller failed with exit code $($process.ExitCode)." }
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
    if ($DeploymentType -eq 'Uninstall') {
        Remove-GitForWindows
        Write-Log -Message "Completed '$SoftwareName' Uninstall."
        return
    }

    Remove-GitForWindows
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No EXE installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one EXE installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $GitInstaller = $InstallerFiles[0].FullName

    # Write setup INF to temp directory
    New-Item -Path $TempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $TempDirCreated = $true
    $InfPath = Join-Path $TempDir 'setup.inf'
    $SetupIni | Out-File -FilePath $InfPath -Encoding unicode -ErrorAction Stop
    Write-Log -Message "Setup INF written to '$InfPath'."

    # Install
    $ArgumentList = "/VERYSILENT /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /LOADINF=`"$InfPath`""
    Write-Log -Message "Installing '$SoftwareName' via: '$GitInstaller $ArgumentList'."
    $installerProcess = Start-Process -FilePath $GitInstaller -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
    if (-not $installerProcess.WaitForExit(600000)) { $installerProcess.Kill(); throw "'$SoftwareName' installer timed out." }
    if ($installerProcess.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer exited with code $($installerProcess.ExitCode)." }
    Write-Log -Message "'$SoftwareName' installed successfully."

    Write-Log -Message "Completed '$SoftwareName' Install."
}
catch {
    Write-Log -Category Error -Message "Script failed: $_"
    throw
}
finally {
    if ($TempDirCreated -and (Test-Path -Path $TempDir)) {
        Write-Log -Message "Cleaning up temporary directory '$TempDir'."
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

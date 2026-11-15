param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'Git for Windows'

#endregion

#region Functions
function Write-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Category = 'Info'
    )
    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if ($env:SUPPRESS_FILELOG -ne '1') {
        Add-Content -LiteralPath $script:Log -Value $content -ErrorAction Stop
    }
    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    param (
        [Parameter(Position = 0)][string]$Path,
        [string]$Name = 'Artifact',
        [string]$FilePath
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    if ($FilePath) {
        $script:Log = $FilePath
        $Path = Split-Path $FilePath -Parent
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A log directory or FilePath is required.' }
        $script:Log = Join-Path $Path "$Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    }
    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Add-Content -LiteralPath $script:Log -Value "Date`t`t`tCategory`t`tDetails" -ErrorAction Stop
}

function Invoke-ApplicationProcess {
    param (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
    # Windows PowerShell needs a retained handle to read ExitCode after WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "$Action timed out." }
    if ($null -eq $process.ExitCode) { throw "$Action did not report an exit code." }
    if ($SuccessExitCodes.Count -gt 0 -and $process.ExitCode -notin $SuccessExitCodes) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }
    return $process
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
New-Log -Path (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs\Software') -Name 'Deploy-GitforWindows'
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

$TempDir = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\Git'
$TempDirCreated = $false

try {
    $uninstallerPath = Join-Path $env:ProgramFiles 'Git\unins000.exe'
    if (Test-Path -LiteralPath $uninstallerPath -PathType Leaf) {
        Write-Log -Message "Removing '$SoftwareName' with '$uninstallerPath /VERYSILENT /NORESTART'."
        $null = Invoke-ApplicationProcess -FilePath $uninstallerPath -ArgumentList '/VERYSILENT /NORESTART' `
            -Action "'$SoftwareName' uninstaller" -SuccessExitCodes $SuccessExitCodes
    }
    else {
        Write-Log -Message "'$SoftwareName' is not installed."
    }
    if ($DeploymentType -eq 'Uninstall') {
        Write-Log -Message "Completed '$SoftwareName' Uninstall."
        return
    }

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
    $null = Invoke-ApplicationProcess -FilePath $GitInstaller -ArgumentList $ArgumentList `
        -Action "'$SoftwareName' installer" -SuccessExitCodes $SuccessExitCodes
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

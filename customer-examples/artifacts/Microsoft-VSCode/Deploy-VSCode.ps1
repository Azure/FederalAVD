<#
.SYNOPSIS
    Installs or removes Visual Studio Code silently.

.DESCRIPTION
    Installs the Visual Studio Code executable found in the same directory as this
    script using a fully silent, no-restart installation. Optionally sets the
    machine-wide Group Policy registry value to disable VS Code's built-in update
    mechanism, which is recommended for managed VDI image builds where updates
    should be controlled through the image pipeline rather than the application.

.PARAMETER DisableUpdates
    When set to $true, sets HKLM:\SOFTWARE\Policies\Microsoft\VSCode\UpdateMode
    to 'none', preventing VS Code from automatically checking for and downloading
    updates. Defaults to $false.

.NOTES
        - Exactly one .exe installer must be present in the same directory as this script.
        - Logs are written to C:\Windows\Logs\Deploy-VSCode-<datetime>.log.
    - Designed to run silently in a SYSTEM context during an image build.

.EXAMPLE
    # Install VS Code and allow automatic updates (default)
    .\Deploy-VSCode.ps1 -DisableUpdates $false

.EXAMPLE
    # Remove the machine-wide VS Code installation
    .\Deploy-VSCode.ps1 -DeploymentType Uninstall
#>
[CmdletBinding()]
param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [Parameter()]
    [bool]
    $DisableUpdates = $true,
    [int[]]$SuccessExitCodes = @(0, 3010)
)
#region functions
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

function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][Alias('Key')][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [Alias('Type')][Microsoft.Win32.RegistryValueKind]$PropertyType = 'String'
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force -ErrorAction Stop | Out-Null
}

#endregion Functions

#region Initialization
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
New-Log 'C:\Windows\Logs' -Name 'Deploy-VSCode'
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
#endregion

$ProcessTimeoutMs = 300000
if ($DeploymentType -eq 'Uninstall') {
    $UninstallerPath = Join-Path -Path $Env:ProgramFiles -ChildPath 'Microsoft VS Code\unins000.exe'
    if (-not (Test-Path -LiteralPath $UninstallerPath -PathType Leaf)) {
        Write-Log -Message 'Visual Studio Code is not installed.'
    }
    else {
        $Arguments = '/VERYSILENT /NORESTART'
        Write-Log -Message "Removing Visual Studio Code with '$UninstallerPath $Arguments'."
        $Process = Invoke-ApplicationProcess -FilePath $UninstallerPath -ArgumentList $Arguments `
            -Action 'Visual Studio Code uninstaller' -TimeoutMs $ProcessTimeoutMs -SuccessExitCodes @()
        if ($Process.ExitCode -notin $SuccessExitCodes) { throw "Visual Studio Code uninstaller failed with exit code $($Process.ExitCode)." }
    }
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No EXE installer found for Visual Studio Code in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one EXE installer for Visual Studio Code, but found: $($InstallerFiles.Name -join ', ')" }
    $VSCodeExe = $InstallerFiles[0].FullName
    $Arguments = '/VERYSILENT /NORESTART /MERGETASKS=!runcode'
    Write-Log -Message "Installing Visual Studio Code with '$VSCodeExe $Arguments'."
    $Process = Invoke-ApplicationProcess -FilePath $VSCodeExe -ArgumentList $Arguments `
        -Action 'Visual Studio Code installer' -TimeoutMs $ProcessTimeoutMs -SuccessExitCodes @()
    if ($Process.ExitCode -notin $SuccessExitCodes) { throw "Visual Studio Code installer failed with exit code $($Process.ExitCode)." }
    Write-Log -Message 'Visual Studio Code installed successfully.'

    if ($DisableUpdates) {
        Write-Log -Category Info -Message 'Disabling VS Code auto-updates via registry.'
        Set-RegistryValue -Key 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode' -Name 'UpdateMode' -Value 'none' -Type 'String'
    }
}

Write-Log -Message "Completed Visual Studio Code $DeploymentType."

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
        [Parameter(Mandatory = $true, Position=0)]
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

Function Set-RegistryValue {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullorEmpty()]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Value,
        [Parameter(Mandatory = $false)]
        [ValidateSet('Binary', 'DWord', 'ExpandString', 'MultiString', 'None', 'QWord', 'String', 'Unknown')]
        [Microsoft.Win32.RegistryValueKind]$Type = 'String'
    )

    [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

    If (-not (Get-ItemProperty -LiteralPath $key -Name $Name -ErrorAction 'SilentlyContinue')) {
        If (-not (Test-Path -LiteralPath $key -ErrorAction 'Stop')) {
            Try {
                Write-Log -Category Info -Message "${CmdletName}: Create registry key [$key]."
                # No forward slash found in Key. Use New-Item cmdlet to create registry key
                If ((($Key -split '/').Count - 1) -eq 0) {
                    $null = New-Item -Path $key -ItemType 'Registry' -Force -ErrorAction 'Stop'
                }
                # Forward slash was found in Key. Use REG.exe ADD to create registry key
                Else {
                    $null = & reg.exe Add "$($Key.Substring($Key.IndexOf('::') + 2))"
                    If ($global:LastExitCode -ne 0) {
                        Throw "Failed to create registry key [$Key]"
                    }
                }
            }
            Catch {
                Throw
            }
        }
        Write-Log -category Info -Message "${CmdletName}: Set registry key value: [$key] [$name = $value]."
        $null = New-ItemProperty -LiteralPath $key -Name $name -Value $value -PropertyType $Type -ErrorAction 'Stop'
    }
    ## Update registry value if it does exist
    Else {
        If ($Name -eq '(Default)') {
            ## Set Default registry key value with the following workaround, because Set-ItemProperty contains a bug and cannot set Default registry key value
            $null = $(Get-Item -LiteralPath $key -ErrorAction 'Stop').OpenSubKey('', 'ReadWriteSubTree').SetValue($null, $value)
        }
        Else {
            Write-Log -category Info -Message "${CmdletName}: Update registry key value: [$key] [$name = $value]."
            $null = Set-ItemProperty -LiteralPath $key -Name $name -Value $value -ErrorAction 'Stop'
        }
    }
}

function Wait-MsiexecIdle {
    # msiexec serializes all MSI transactions through a global Windows Installer mutex.
    # Only one MSI transaction can run at a time. If an Azure Policy deployIfNotExists
    # extension or concurrent deployment holds the lock, this waits up to 5 minutes.
    param ([int]$WaitSeconds = 300)
    $elapsed = 0
    Write-Log -Category Info -Message 'Pre-flight: checking for active msiexec processes...'
    while ($elapsed -lt $WaitSeconds) {
        if (-not (Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited })) { break }
        Write-Log -Category Info -Message "Pre-flight: msiexec is active. Waiting 10 s... ($elapsed / $WaitSeconds s elapsed)"
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    if ($elapsed -ge $WaitSeconds) {
        Write-Log -Category Warning -Message "Pre-flight: msiexec was still active after $WaitSeconds seconds. Installation may queue or fail."
    }
    else {
        Write-Log -Category Info -Message 'Pre-flight: msiexec serialization lock is free.'
    }
}

#endregion Functions

#region Initialization
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
New-Log 'C:\Windows\Logs'
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
        $Process = Start-Process -FilePath $UninstallerPath -ArgumentList $Arguments -PassThru
        if (-not $Process.WaitForExit($ProcessTimeoutMs)) { $Process.Kill(); throw 'Visual Studio Code uninstaller timed out.' }
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
    Wait-MsiexecIdle
    $Process = Start-Process -FilePath $VSCodeExe -ArgumentList $Arguments -PassThru
    if (-not $Process.WaitForExit($ProcessTimeoutMs)) { $Process.Kill(); throw 'Visual Studio Code installer timed out.' }
    if ($Process.ExitCode -notin $SuccessExitCodes) { throw "Visual Studio Code installer failed with exit code $($Process.ExitCode)." }
    Write-Log -Message 'Visual Studio Code installed successfully.'

    if ($DisableUpdates) {
        Write-Log -Category Info -Message 'Disabling VS Code auto-updates via registry.'
        Set-RegistryValue -Key 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode' -Name 'UpdateMode' -Value 'none' -Type 'String'
    }
}

Write-Log -Message "Completed Visual Studio Code $DeploymentType."


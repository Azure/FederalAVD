<#
.SYNOPSIS
    Installs Visual Studio Code silently and optionally disables automatic updates.

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
    - The installer executable (.exe) must be present in the same directory as
      this script. The first .exe file found is used.
    - Logs are written to C:\Windows\Logs\Install_VSCode-<datetime>.log.
    - Designed to run silently in a SYSTEM context during an image build.

.EXAMPLE
    # Install VS Code and allow automatic updates (default)
    .\Install_VSCode.ps1

.EXAMPLE
    # Install VS Code and disable automatic updates
    .\Install_VSCode.ps1 -DisableUpdates $true
#>
[CmdletBinding()]
param (
    [Parameter()]
    [bool]
    $DisableUpdates = $true
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
$DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=852157'
New-Log 'C:\Windows\Logs'
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."
#endregion

$DownloadedInstaller = $null

try {
    #region Locate or download installer
    $installerFiles = @(Get-ChildItem -Path $PSScriptRoot -File -Filter '*.exe' -ErrorAction Stop | Sort-Object LastWriteTime -Descending)
    if ($installerFiles.Count -gt 0) {
        $VSCodeExe = $installerFiles[0].FullName
        Write-Log -Category Info -Message "Found local installer: '$VSCodeExe'."
    }
    else {
        Write-Log -Category Warning -Message "No installer executable found in '$PSScriptRoot'. Attempting download from '$DownloadUrl'."
        Write-Log -Category Warning -Message "NOTE: When run as an Azure Run Command, PSScriptRoot resolves to a temp path, not the artifacts directory. Place the installer .exe alongside this script in the artifacts storage container."
        $DownloadedInstaller = Join-Path -Path $env:Temp -ChildPath 'VSCodeInstaller.exe'
        try {
            # TimeoutSec is required -- Invoke-WebRequest has no default timeout in PowerShell 5.1
            # and will hang indefinitely in network-restricted image build environments.
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $DownloadedInstaller -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        }
        catch {
            Write-Log -Category Error -Message "Failed to download VS Code installer from '$DownloadUrl'. Error: $_"
            throw
        }
        if (-not (Test-Path -Path $DownloadedInstaller)) {
            $errMsg = "Installer download appeared to succeed but file not found at '$DownloadedInstaller'."
            Write-Log -Category Error -Message $errMsg
            throw $errMsg
        }
        $VSCodeExe = $DownloadedInstaller
        Write-Log -Category Info -Message "Installer downloaded to '$VSCodeExe'."
    }
    #endregion

    #region Install
    # Standard silent install switches per VS Code documentation.
    # /VERYSILENT  -- suppresses all UI including the progress window
    # /NORESTART   -- prevents automatic reboot (image build handles reboots explicitly)
    # /MERGETASKS=!runcode -- deselects the "Launch VS Code after install" task
    #
    # NOTE: The System installer (linkid=852157) installs machine-wide by default and requires
    # no additional switches for SYSTEM-context execution.
    $Arguments = '/VERYSILENT /NORESTART /MERGETASKS=!runcode'
    $InstallerTimeoutMs = 300000 # 5 minutes -- covers the WM_SETTINGCHANGE PATH broadcast delay
    Write-Log -Category Info -Message "Starting installation of VS Code from '$VSCodeExe'."
    Write-Log -Category Info -Message "Executing: '$VSCodeExe $Arguments'."
    Wait-MsiexecIdle
    try {
        $installerProcess = Start-Process -FilePath $VSCodeExe -ArgumentList $Arguments -PassThru -ErrorAction Stop
    }
    catch {
        Write-Log -Category Error -Message "Failed to launch VS Code installer. Error: $_"
        throw
    }
    if (-not $installerProcess.WaitForExit($InstallerTimeoutMs)) {
        $installerProcess.Kill()
        $errMsg = "VS Code installer did not complete within $($InstallerTimeoutMs / 60000) minutes and was terminated."
        Write-Log -Category Error -Message $errMsg
        throw $errMsg
    }
    if ($installerProcess.ExitCode -eq 0) {
        Write-Log -Category Info -Message 'VS Code installed successfully.'
    }
    else {
        $errMsg = "VS Code installer exited with non-zero exit code: $($installerProcess.ExitCode)."
        Write-Log -Category Error -Message $errMsg
        throw $errMsg
    }
    #endregion Install

    #region Disable Updates
    if ($DisableUpdates) {
        Write-Log -Category Info -Message 'Disabling VS Code auto-updates via registry.'
        try {
            Set-RegistryValue -Key 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode' -Name 'UpdateMode' -Value 'none' -Type 'String'
        }
        catch {
            Write-Log -Category Error -Message "Failed to set VS Code update registry value. Error: $_"
            throw
        }
    }
    #endregion Disable Updates

    Write-Log -Category Info -Message "Ending '$PSCommandPath'."
}
catch {
    Write-Log -Category Error -Message "Script failed: $_"
    exit 1
}
finally {
    if ($null -ne $DownloadedInstaller -and (Test-Path -Path $DownloadedInstaller)) {
        Write-Log -Category Info -Message "Removing temporary installer file '$DownloadedInstaller'."
        Remove-Item -Path $DownloadedInstaller -Force -ErrorAction SilentlyContinue
    }
}


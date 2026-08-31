param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'Microsoft Power BI Desktop'
$Script:Name = 'Deploy-PowerBIDesktop'
#endregion

#region Supporting Functions
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

function Remove-PowerBIDesktop {
    param ([int]$TimeoutMs = 600000)
    $registryPaths = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $registrations = @(
        foreach ($registryPath in $registryPaths) {
            if (Test-Path -LiteralPath $registryPath) {
                Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $application = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($application.DisplayName -like 'Microsoft Power BI Desktop*' -and $application.Publisher -like 'Microsoft*') {
                        $application
                    }
                }
            }
        }
    )
    if (-not $registrations) { Write-Log -Message "'$SoftwareName' is not installed."; return }
    if ($registrations.Count -gt 1) { throw "Multiple Power BI Desktop installations matched: $(($registrations.DisplayName) -join ', ')" }
    $command = $registrations[0].QuietUninstallString
    if (-not $command) { throw "'$SoftwareName' does not provide a quiet uninstall command." }
    if ($command -notmatch '^\s*"([^"]+\.exe)"\s*(.*)$' -and $command -notmatch '^\s*(.+?\.exe)\s+(.*)$') {
        throw "Could not parse '$SoftwareName' quiet uninstall command."
    }
    $uninstallerPath = $Matches[1]
    $arguments = $Matches[2]
    if (-not (Test-Path -LiteralPath $uninstallerPath -PathType Leaf)) { throw "'$SoftwareName' uninstaller not found at '$uninstallerPath'." }
    Write-Log -Message "Removing '$SoftwareName' with its registered quiet uninstaller."
    $process = Start-Process -FilePath $uninstallerPath -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "'$SoftwareName' uninstaller timed out." }
    if ($process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' uninstaller failed with exit code $($process.ExitCode)." }
}

#endregion

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -message "Starting '$PSCommandPath'."
$ProcessTimeoutMs = 600000
if ($DeploymentType -eq 'Uninstall') {
    Remove-PowerBIDesktop -TimeoutMs $ProcessTimeoutMs
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No EXE installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one EXE installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $Installer = $InstallerFiles[0].FullName
    $Process = Start-Process -FilePath $Installer -ArgumentList '-quiet -norestart ACCEPT_EULA=1 DISABLE_UPDATE_NOTIFICATION=1 ENABLECXP=0' -PassThru
    if (-not $Process.WaitForExit($ProcessTimeoutMs)) { $Process.Kill(); throw "'$SoftwareName' installer timed out." }
    if ($Process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer failed with exit code $($Process.ExitCode)." }
    Write-Log -message "'$SoftwareName' installed successfully."
}

Write-Log -Message "Completed '$SoftwareName' $DeploymentType."

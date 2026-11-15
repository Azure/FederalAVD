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

function Get-InstalledApplications {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Publisher = '*',
        [string[]]$RegistryPaths = @(
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        ),
        [string]$ProductCodePattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$',
        [switch]$RegEx,
        [switch]$WindowsInstaller
    )
    foreach ($registryPath in $RegistryPaths) {
        if (Test-Path -LiteralPath $registryPath) {
            Get-ChildItem -LiteralPath $registryPath -ErrorAction Stop | ForEach-Object {
                $application = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                $isWindowsInstaller = $application.WindowsInstaller -eq 1
                $productCode = if ($isWindowsInstaller -and $_.PSChildName -match $ProductCodePattern) { $_.PSChildName } else { '' }
                $nameMatches = if ($RegEx) { $application.DisplayName -match $Name } else { $application.DisplayName -like $Name }
                if ($nameMatches -and ($Publisher -eq '*' -or $application.Publisher -like $Publisher) -and
                    (-not $WindowsInstaller -or $productCode)) {
                    [pscustomobject]@{
                        DisplayName = $application.DisplayName
                        DisplayVersion = $application.DisplayVersion
                        Publisher = $application.Publisher
                        InstallLocation = $application.InstallLocation
                        ProductCode = $productCode
                        WindowsInstaller = $isWindowsInstaller
                        RegistryPath = $_.PSPath
                        QuietUninstallString = $application.QuietUninstallString
                        BundleCachePath = $application.BundleCachePath
                    }
                }
            }
        }
    }
}

function Split-ExecutableCommandLine {
    param ([Parameter(Mandatory = $true)][string]$CommandLine)
    if ($CommandLine -notmatch '^\s*"([^"]+\.exe)"\s*(.*)$' -and $CommandLine -notmatch '^\s*(.+?\.exe)\s+(.*)$') {
        throw 'Could not parse the executable command line.'
    }
    [pscustomobject]@{ FilePath = $Matches[1]; ArgumentList = $Matches[2] }
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

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Deploy-PowerBIDesktop'
$ErrorActionPreference = 'Stop'
Write-Log -message "Starting '$PSCommandPath'."
$ProcessTimeoutMs = 600000
if ($DeploymentType -eq 'Uninstall') {
    $registrations = @(Get-InstalledApplications -Name 'Microsoft Power BI Desktop*' -Publisher 'Microsoft*')
    if ($registrations.Count -gt 1) { throw "Multiple Power BI Desktop installations matched: $(($registrations.DisplayName) -join ', ')" }
    if ($registrations.Count -eq 0) {
        Write-Log -Message "'$SoftwareName' is not installed."
    }
    else {
        if (-not $registrations[0].QuietUninstallString) { throw "'$SoftwareName' does not provide a quiet uninstall command." }
        $command = Split-ExecutableCommandLine -CommandLine $registrations[0].QuietUninstallString
        if (-not (Test-Path -LiteralPath $command.FilePath -PathType Leaf)) { throw "'$SoftwareName' uninstaller not found at '$($command.FilePath)'." }
        Write-Log -Message "Removing '$SoftwareName' with its registered quiet uninstaller."
        $null = Invoke-ApplicationProcess -FilePath $command.FilePath -ArgumentList $command.ArgumentList `
            -Action "'$SoftwareName' uninstaller" -SuccessExitCodes $SuccessExitCodes -TimeoutMs $ProcessTimeoutMs
    }
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No EXE installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one EXE installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $Installer = $InstallerFiles[0].FullName
    $null = Invoke-ApplicationProcess -FilePath $Installer `
        -ArgumentList '-quiet -norestart ACCEPT_EULA=1 DISABLE_UPDATE_NOTIFICATION=1 ENABLECXP=0' `
        -Action "'$SoftwareName' installer" -SuccessExitCodes $SuccessExitCodes -TimeoutMs $ProcessTimeoutMs
    Write-Log -message "'$SoftwareName' installed successfully."
}

Write-Log -Message "Completed '$SoftwareName' $DeploymentType."

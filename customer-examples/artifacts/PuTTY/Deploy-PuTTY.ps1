param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'PuTTY'
$Script:Name = 'Deploy-PuTTY'
#endregion

#region Supporting Functions
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

function Invoke-MsiProcess {
    param (
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int]$TimeoutMs = 600000,
        [int]$MaxAttempts = 11,
        [int]$RetryDelaySeconds = 30
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $process = Invoke-ApplicationProcess -FilePath 'msiexec.exe' -ArgumentList $ArgumentList `
            -Action $Action -TimeoutMs $TimeoutMs -SuccessExitCodes @()
        if ($process.ExitCode -ne 1618) { return $process }
        if ($attempt -eq $MaxAttempts) {
            throw "$Action failed after $MaxAttempts attempts with exit code 1618 (another installation is already in progress)."
        }
        Write-Log -Category Warning -Message "$Action returned exit code 1618. Retrying in $RetryDelaySeconds seconds (attempt $attempt of $MaxAttempts)."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
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

function Remove-MsiApplications {
    param (
        [object[]]$Applications = @(),
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000,
        [switch]$AllowMultiple,
        [switch]$VerifyRemoval,
        [string]$ArgumentListFormat = '/x {0} /qn /norestart'
    )
    if ($Applications.Count -eq 0) {
        Write-Log -Message 'No matching MSI installation was found.'
        return
    }
    if (-not $AllowMultiple -and $Applications.Count -gt 1) {
        $matchesText = ($Applications | ForEach-Object { "$($_.DisplayName) [$($_.ProductCode)]" }) -join ', '
        throw "Multiple MSI installations matched: $matchesText"
    }
    if ($AllowMultiple) { $Applications = @($Applications | Sort-Object ProductCode -Unique) }
    if (-not $ArgumentListFormat.Contains('{0}')) { throw 'MSI uninstall arguments must include the {0} ProductCode placeholder.' }
    foreach ($installedApplication in $Applications) {
        if ($installedApplication.ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
            throw "A valid MSI ProductCode is required to remove '$($installedApplication.DisplayName)'."
        }
        Write-Log -Message "Removing '$($installedApplication.DisplayName)' with ProductCode '$($installedApplication.ProductCode)'."
        $uninstaller = Invoke-MsiProcess -ArgumentList ($ArgumentListFormat -f $installedApplication.ProductCode) `
            -Action "'$($installedApplication.DisplayName)' uninstaller" -TimeoutMs $TimeoutMs
        if ($uninstaller.ExitCode -notin $SuccessExitCodes) {
            throw "'$($installedApplication.DisplayName)' uninstaller failed with exit code $($uninstaller.ExitCode)."
        }
        if ($uninstaller.ExitCode -eq 3010) { Write-Log -Category Warning -Message 'MSI removal requires a reboot.' }
        if ($VerifyRemoval) {
            if ([string]::IsNullOrWhiteSpace($installedApplication.RegistryPath)) {
                throw 'RegistryPath is required to verify MSI removal.'
            }
            if (Test-Path -LiteralPath $installedApplication.RegistryPath) {
                throw "MSI registration remains after removal: '$($installedApplication.ProductCode)'."
            }
        }
        Write-Log -Message "'$($installedApplication.DisplayName)' uninstall completed successfully."
    }
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Deploy-PuTTY'
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes
if ($DeploymentType -eq 'Uninstall') {
    $applications = @(Get-InstalledApplications -Name 'PuTTY release *' -Publisher 'Simon Tatham' -WindowsInstaller)
    Remove-MsiApplications -Applications $applications -SuccessExitCodes $SuccessExitCodes -TimeoutMs $InstallerTimeoutMs
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.msi' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No MSI installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one MSI installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathMSI = $InstallerFiles[0].FullName
    Write-Log -Category Info -message "Installing '$SoftwareName' via cmdline: 'msiexec /i `"$PathMSI`" /qn /norestart'."
    $Installer = Invoke-MsiProcess -ArgumentList "/i `"$PathMSI`" /qn /norestart" -Action "'$SoftwareName' installer" -TimeoutMs $InstallerTimeoutMs
    if ($Installer.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer failed with exit code $($Installer.ExitCode)." }
    if ($Installer.ExitCode -eq 3010) { Write-Log -Message "'$SoftwareName' installed successfully. A reboot is required." }
    else { Write-Log -Message "'$SoftwareName' installed successfully." }
}

Write-Log -Category Info -message "Completed '$SoftwareName' $DeploymentType."

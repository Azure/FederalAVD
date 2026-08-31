param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = '7-Zip'
$Script:Name = 'Deploy-7-Zip'
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

function Wait-MsiexecIdle {
    [CmdletBinding()]
    param (
        [int]$WaitSeconds = 300
    )
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

function Remove-MSIApplication {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$TimeoutMs = 600000
    )

    $uninstallRegistryPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $installedApplications = @(
        if (Test-Path -LiteralPath $uninstallRegistryPath) {
            Get-ChildItem -LiteralPath $uninstallRegistryPath -ErrorAction SilentlyContinue | ForEach-Object {
                $application = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($application.DisplayName -like "*$Name*" -and
                    $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                    [pscustomobject]@{
                        DisplayName = $application.DisplayName
                        ProductCode = $_.PSChildName
                    }
                }
            }
        }
    )

    if ($installedApplications.Count -eq 0) {
        Write-Log -Category Info -Message "No MSI installation of '$Name' was found."
        return
    }
    if ($installedApplications.Count -gt 1) {
        $matches = ($installedApplications | ForEach-Object { "$($_.DisplayName) [$($_.ProductCode)]" }) -join ', '
        throw "Multiple MSI installations matched '$Name': $matches"
    }

    $installedApplication = $installedApplications[0]
    Write-Log -Category Info -Message "Removing '$($installedApplication.DisplayName)' with ProductCode '$($installedApplication.ProductCode)'."
    Wait-MsiexecIdle
    $uninstaller = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $($installedApplication.ProductCode) /quiet /qn /norestart" -PassThru
    if (-not $uninstaller.WaitForExit($TimeoutMs)) {
        $uninstaller.Kill()
        throw "'$Name' MSI uninstaller timed out after $($TimeoutMs / 60000) minutes and was terminated."
    }
    if ($uninstaller.ExitCode -notin $SuccessExitCodes) {
        throw "'$Name' MSI uninstaller failed with exit code $($uninstaller.ExitCode)."
    }

    Write-Log -Category Info -Message "'$Name' MSI uninstall completed successfully."
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes

if ($DeploymentType -eq 'Uninstall') {
    Remove-MSIApplication -Name $SoftwareName -TimeoutMs $InstallerTimeoutMs
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.msi' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No MSI installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one MSI installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathMSI = $InstallerFiles[0].FullName
    Write-Log -Category Info -message "Installing '$SoftwareName' via MSI: 'msiexec /i `"$PathMSI`" /quiet /noreboot'."
    Wait-MsiexecIdle
    $Installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$PathMSI`" /quiet /noreboot" -PassThru
    if (-not $Installer.WaitForExit($InstallerTimeoutMs)) {
        $Installer.Kill()
        Write-Log -Category Error -Message "'$SoftwareName' MSI installer timed out after $($InstallerTimeoutMs / 60000) minutes and was terminated."
        exit 1
    }
    elseif ($Installer.ExitCode -in $SuccessExitCodes) {
        if ($Installer.ExitCode -eq 3010) { Write-Log -Category Info -message "'$SoftwareName' installed successfully. A reboot is required." }
        else { Write-Log -Category Info -message "'$SoftwareName' installed successfully." }
    }
    else {
        Write-Log -Category Error -Message "'$SoftwareName' MSI installer failed with exit code $($Installer.ExitCode)."
        exit $Installer.ExitCode
    }
}

Write-Log -Category Info -message "Completed '$SoftwareName' $DeploymentType."

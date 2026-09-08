param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'InstallRoot'
$Script:Name = 'Deploy-InstallRoot'
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

function Invoke-MsiProcess {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArgumentList,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [int]$TimeoutMs = 600000,
        [int]$MaxAttempts = 11,
        [int]$RetryDelaySeconds = 30
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $ArgumentList -PassThru
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            throw "$Action timed out after $($TimeoutMs / 60000) minutes and was terminated."
        }
        if ($process.ExitCode -ne 1618) { return $process }
        if ($attempt -eq $MaxAttempts) {
            throw "$Action failed after $MaxAttempts attempts with exit code 1618 (another installation is already in progress)."
        }
        Write-Log -Category Warning -Message "$Action returned exit code 1618. Retrying in $RetryDelaySeconds seconds (attempt $attempt of $MaxAttempts)."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Remove-MSIApplication {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$TimeoutMs = 600000
    )

    $uninstallRegistryPaths = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $installedApplications = @(
        foreach ($uninstallRegistryPath in $uninstallRegistryPaths) {
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
        }
    )

    if ($installedApplications.Count -eq 0) {
        Write-Log -Category Info -Message "No MSI installation of '$Name' was found."
        return
    }
    if ($installedApplications.Count -gt 1) {
        $matchedApplications = ($installedApplications | ForEach-Object { "$($_.DisplayName) [$($_.ProductCode)]" }) -join ', '
        throw "Multiple MSI installations matched '$Name': $matchedApplications"
    }

    $installedApplication = $installedApplications[0]
    Write-Log -Category Info -Message "Removing '$($installedApplication.DisplayName)' with ProductCode '$($installedApplication.ProductCode)'."
    $uninstaller = Invoke-MsiProcess -ArgumentList "/x $($installedApplication.ProductCode) /quiet /qn /norestart" -Action "'$Name' MSI uninstaller" -TimeoutMs $TimeoutMs
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
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes

if ($DeploymentType -eq 'Uninstall') {
    Remove-MSIApplication -Name $SoftwareName -TimeoutMs $InstallerTimeoutMs
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.msi' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No MSI installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one MSI installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathMSI = $InstallerFiles[0].FullName
    Write-Log -Category Info -Message "Installing '$SoftwareName' via MSI: 'msiexec /i `"$PathMSI`" /qn /norestart'."
    $Installer = Invoke-MsiProcess -ArgumentList "/i `"$PathMSI`" /qn /norestart" -Action "'$SoftwareName' MSI installer" -TimeoutMs $InstallerTimeoutMs
    if ($Installer.ExitCode -in $SuccessExitCodes) {
        if ($Installer.ExitCode -eq 3010) { Write-Log -Category Info -Message "'$SoftwareName' installed successfully. A reboot is required." }
        else { Write-Log -Category Info -Message "'$SoftwareName' installed successfully." }

        $shortcutWaitSeconds = 20
        for ($attempt = 1; $attempt -le $shortcutWaitSeconds; $attempt++) {
            $shortcuts = @(Get-ChildItem -Path "$env:SystemDrive\Users\Public\Desktop" -Filter 'InstallRoot*.lnk' -ErrorAction SilentlyContinue)
            if ($shortcuts.Count -gt 0) {
                $shortcuts | Remove-Item -Force
                break
            }
            Start-Sleep -Seconds 1
        }
    }
    else {
        Write-Log -Category Error -Message "'$SoftwareName' MSI installer failed with exit code $($Installer.ExitCode)."
        exit $Installer.ExitCode
    }
}

Write-Log -Category Info -Message "Completed '$SoftwareName' $DeploymentType."

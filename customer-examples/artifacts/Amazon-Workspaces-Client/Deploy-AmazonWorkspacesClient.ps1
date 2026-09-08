[CmdletBinding()]
param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [Parameter()]
    [bool]$DisableUpdates = $true,
    [int[]]$SuccessExitCodes = @(0, 3010)
)
#region Initialization
$SoftwareName = 'Amazon WorkSpaces'
$Script:Name = 'Deploy-AmazonWorkspacesClient'
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

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name,
        [Parameter()]
        [string]
        $Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )
    Begin {
        Write-Log -message "[Set-RegistryValue]: Setting Registry Value: $Name"
    }
    Process {
        # Create the registry Key(s) if necessary.
        If (!(Test-Path -Path $Path)) {
            Write-Log -message "[Set-RegistryValue]: Creating Registry Key: $Path"
            New-Item -Path $Path -Force | Out-Null
        }
        # Check for existing registry setting
        $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($RemoteValue) {
            # Get current Value
            $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
            Write-Log -message "[Set-RegistryValue]: Current Value of $($Path)\$($Name) : $CurrentValue"
            If ($Value -ne $CurrentValue) {
                Write-Log -message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            }
            Else {
                Write-Log -message "[Set-RegistryValue]: Value of $($Path)\$($Name) is already set to $Value"
            }          
        }
        Else {
            Write-Log -message "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    End {
    }
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

function Remove-AmazonWorkSpacesClient {
    param ([int]$TimeoutMs = 600000)
    $registryPaths = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $installedApplications = @(
        foreach ($registryPath in $registryPaths) {
            if (Test-Path -LiteralPath $registryPath) {
                Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $application = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($application.DisplayName -like 'Amazon WorkSpaces*' -and
                        $application.Publisher -like 'Amazon Web Services*' -and
                        $_.PSChildName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
                        [pscustomobject]@{ DisplayName = $application.DisplayName; ProductCode = $_.PSChildName }
                    }
                }
            }
        }
    )
    if (-not $installedApplications) { Write-Log -Message "No MSI installation of '$SoftwareName' was found."; return }
    if ($installedApplications.Count -gt 1) { throw "Multiple Amazon WorkSpaces MSI installations matched: $(($installedApplications.DisplayName) -join ', ')" }
    $installedApplication = $installedApplications[0]
    Write-Log -Message "Removing '$($installedApplication.DisplayName)' with ProductCode '$($installedApplication.ProductCode)'."
    $process = Invoke-MsiProcess -ArgumentList "/x $($installedApplication.ProductCode) /qn /norestart" -Action "'$SoftwareName' uninstaller" -TimeoutMs $TimeoutMs
    if ($process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' uninstaller failed with exit code $($process.ExitCode)." }
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes
if ($DeploymentType -eq 'Uninstall') {
    Remove-AmazonWorkSpacesClient -TimeoutMs $InstallerTimeoutMs
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.msi' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No MSI installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one MSI installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathMSI = $InstallerFiles[0].FullName
    Write-Log -Message "Installing '$SoftwareName' via cmdline: 'msiexec /i `"$PathMSI`" /qn /norestart ALLUSERS=1'."
    $Installer = Invoke-MsiProcess -ArgumentList "/i `"$PathMSI`" /qn /norestart ALLUSERS=1" -Action "'$SoftwareName' installer" -TimeoutMs $InstallerTimeoutMs
    if ($Installer.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer failed with exit code $($Installer.ExitCode)." }
    if ($Installer.ExitCode -eq 3010) { Write-Log -Message "'$SoftwareName' installed successfully. A reboot is required." }
    else { Write-Log -Message "'$SoftwareName' installed successfully." }
    if ($DisableUpdates) {
        Set-RegistryValue -Name 'clientUpgradeDisabled' -Path 'HKLM:\SOFTWARE\WOW6432Node\Amazon\Amazon WorkSpaces Client' -PropertyType 'STRING' -Value 1
    }
}

Write-Log -Category Info -message "Completed '$SoftwareName' $DeploymentType."

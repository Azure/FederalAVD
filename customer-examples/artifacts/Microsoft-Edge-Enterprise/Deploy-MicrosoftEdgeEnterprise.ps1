[CmdletBinding()]
param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [Parameter()]
    [bool]$DisableUpdates = $true,
    [int[]]$SuccessExitCodes = @(0, 3010)
)
#region Initialization
$SoftwareName = 'Microsoft Edge Enterprise'
$Script:Name  = 'Deploy-MicrosoftEdgeEnterprise'
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

    if ((Test-Path $path) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

function Wait-MsiexecIdle {
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

Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()] [string] $Name,
        [Parameter()] [string] $Path,
        [Parameter()] [string] $PropertyType,
        [Parameter()] $Value
    )
    Begin { Write-Log -Message "[Set-RegistryValue]: Setting $Path\$Name = $Value" }
    Process {
        If (!(Test-Path -Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        If ($existing) {
            $current = Get-ItemPropertyValue -Path $Path -Name $Name
            If ($Value -ne $current) {
                Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
            }
            Else {
                Write-Log -Message "[Set-RegistryValue]: $Name is already set to $Value"
            }
        }
        Else {
            New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
        }
    }
}

function Remove-EdgeEnterprise {
    param ([int]$TimeoutMs = 600000)
    $registryPaths = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $matches = @(
        foreach ($registryPath in $registryPaths) {
            if (Test-Path -LiteralPath $registryPath) {
                Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $application = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($application.DisplayName -eq 'Microsoft Edge' -and
                        $application.Publisher -like 'Microsoft*' -and
                        $_.PSChildName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
                        [pscustomobject]@{ DisplayName = $application.DisplayName; ProductCode = $_.PSChildName }
                    }
                }
            }
        }
    )
    if (-not $matches) { Write-Log -Message "No enterprise MSI installation of '$SoftwareName' was found."; return }
    if ($matches.Count -gt 1) { throw "Multiple Microsoft Edge MSI installations matched: $(($matches.ProductCode) -join ', ')" }
    Write-Log -Message "Removing '$SoftwareName' with ProductCode '$($matches[0].ProductCode)'."
    Wait-MsiexecIdle
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $($matches[0].ProductCode) /qn /norestart" -PassThru
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "'$SoftwareName' uninstaller timed out." }
    if ($process.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' uninstaller failed with exit code $($process.ExitCode)." }
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes

#endregion

if ($DeploymentType -eq 'Uninstall') {
    Remove-EdgeEnterprise -TimeoutMs $InstallerTimeoutMs
}
else {
    $InstallerFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.msi' -File)
    if ($InstallerFiles.Count -eq 0) { throw "No MSI installer found for '$SoftwareName' in '$PSScriptRoot'." }
    if ($InstallerFiles.Count -gt 1) { throw "Expected one MSI installer for '$SoftwareName', but found: $($InstallerFiles.Name -join ', ')" }
    $PathMSI = $InstallerFiles[0].FullName
    Write-Log -Message "Installing '$SoftwareName' via: 'msiexec /i `"$PathMSI`" /qn /norestart'."
    Wait-MsiexecIdle
    $Installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$PathMSI`" /qn /norestart" -PassThru
    if (-not $Installer.WaitForExit($InstallerTimeoutMs)) { $Installer.Kill(); throw "'$SoftwareName' installer timed out." }
    if ($Installer.ExitCode -notin $SuccessExitCodes) { throw "'$SoftwareName' installer failed with exit code $($Installer.ExitCode)." }
    if ($Installer.ExitCode -eq 3010) { Write-Log -Message "'$SoftwareName' installed successfully. A reboot is required." }
    else { Write-Log -Message "'$SoftwareName' installed successfully." }

    if ($DisableUpdates) {
        Write-Log -Message "Disabling '$SoftwareName' auto-updates via registry policy."
        $updatePaths = @(
            'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate',
            'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\EdgeUpdate'
        )
        foreach ($regPath in $updatePaths) {
            Set-RegistryValue -Name 'UpdateDefault' -Path $regPath -PropertyType 'DWORD' -Value 0
        }
    }
}

Write-Log -Category Info -Message "Completed '$SoftwareName' $DeploymentType."

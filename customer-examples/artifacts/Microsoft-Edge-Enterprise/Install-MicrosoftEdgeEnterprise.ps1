[CmdletBinding()]
param (
    [Parameter()]
    [bool]$DisableUpdates = $true,
    [int[]]$SuccessExitCodes = @(0, 3010)
)
#region Initialization
$SoftwareName = 'Microsoft Edge Enterprise'
$Script:Name  = 'Install-MicrosoftEdgeEnterprise'
$EdgeApiUrl   = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
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

function Get-EdgeEnterpriseUrl {
    Write-Log -Category Info -Message "Resolving latest '$SoftwareName' MSI URL from Edge Updates API..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $content = (Invoke-WebRequest -Uri $EdgeApiUrl -UseBasicParsing).Content | ConvertFrom-Json
    $releases = ($content | Where-Object { $_.Product -eq 'Stable' }).releases
    $latest = $releases |
        Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } |
        Sort-Object ProductVersion |
        Select-Object -Last 1
    if (-not $latest) {
        throw "Could not resolve latest '$SoftwareName' release from '$EdgeApiUrl'."
    }
    $msiArtifact = $latest.artifacts | Where-Object { $_.ArtifactName -eq 'msi' }
    if (-not $msiArtifact) {
        throw "No MSI artifact found for '$SoftwareName' version $($latest.ProductVersion)."
    }
    Write-Log -Category Info -Message "Resolved '$SoftwareName' version $($latest.ProductVersion): $($msiArtifact.Location)"
    return $msiArtifact.Location
}

#endregion

## MAIN

#region Initialization

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

$InstallerTimeoutMs = 600000 # 10 minutes

#endregion

#region Resolve Installer

# Use a pre-downloaded MSI if present (supports air-gapped image builds).
# If none is found, download the latest Stable x64 MSI from Microsoft's API.
$PathMSI = (Get-ChildItem -Path $PSScriptRoot -Filter '*.msi' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName

if ($PathMSI) {
    Write-Log -Category Info -Message "Using pre-downloaded MSI: '$PathMSI'."
}
else {
    Write-Log -Category Info -Message "No local MSI found in '$PSScriptRoot'. Downloading from Microsoft..."
    $DownloadUrl  = Get-EdgeEnterpriseUrl
    $DownloadPath = Join-Path $env:TEMP 'MicrosoftEdgeEnterpriseX64.msi'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($DownloadUrl, $DownloadPath)
    Write-Log -Category Info -Message "Downloaded to '$DownloadPath' ($('{0:N1}' -f ((Get-Item $DownloadPath).Length / 1MB)) MB)."
    $PathMSI = $DownloadPath
}

#endregion

#region Install

Write-Log -Category Info -Message "Installing '$SoftwareName' via: 'msiexec /i `"$PathMSI`" /quiet /norestart'."
Wait-MsiexecIdle
$Installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$PathMSI`" /quiet /norestart" -PassThru
if (-not $Installer.WaitForExit($InstallerTimeoutMs)) {
    $Installer.Kill()
    Write-Log -Category Error -Message "'$SoftwareName' installer timed out after $($InstallerTimeoutMs / 60000) minutes and was terminated."
    exit 1
}
elseif ($Installer.ExitCode -in $SuccessExitCodes) {
    if ($Installer.ExitCode -eq 3010) { Write-Log -Category Info -Message "'$SoftwareName' installed successfully. A reboot is required." }
    else { Write-Log -Category Info -Message "'$SoftwareName' installed successfully." }
}
else {
    Write-Log -Category Error -Message "'$SoftwareName' installer failed with exit code $($Installer.ExitCode)."
    exit $Installer.ExitCode
}

#endregion

#region Disable Auto-Updates (optional)

if ($DisableUpdates) {
    Write-Log -Category Info -Message "Disabling '$SoftwareName' auto-updates via registry policy."
    # UpdateDefault = 0 prevents Edge Update from updating any Edge product.
    # This is appropriate for VDI/AVD where the golden image controls the browser version.
    $updatePaths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\EdgeUpdate'
    )
    foreach ($regPath in $updatePaths) {
        Set-RegistryValue -Name 'UpdateDefault' -Path $regPath -PropertyType 'DWORD' -Value 0
    }
}

#endregion

Write-Log -Category Info -Message "Completed '$SoftwareName' installation."

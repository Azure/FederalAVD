<#
.SYNOPSIS
    Installs selected Windows 11 RSAT capabilities from an offline or online source.

.DESCRIPTION
    Installs the Active Directory DS/LDS, Group Policy Management, and DHCP RSAT tools.
    A local Features on Demand source is preferred when it contains CAB files. If the local
    source is missing or cannot install a capability, Windows servicing is allowed to download
    the capability unless OfflineOnly is specified.

.NOTES
    Run as Administrator or SYSTEM. This script is ASCII-only because it can be embedded in ARM.
#>

[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath 'Payload'),

    [switch]$OfflineOnly
)

$ErrorActionPreference = 'Stop'
$Script:Name = 'Install-Windows11RSAT'
$Script:Log = $null

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

function Assert-SupportedHost {
    param (
        [int]$MinimumBuild = 0,
        [switch]$ClientOnly
    )
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM privileges are required.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows operating system is required.' }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt $MinimumBuild) { throw "Windows build $build is unsupported; build $MinimumBuild or later is required." }
    if ($ClientOnly) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $edition = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID
        if ([int]$os.ProductType -ne 1 -and -not ([int]$os.ProductType -eq 3 -and $edition -eq 'ServerRdsh')) {
            throw "Windows client or Enterprise multi-session is required; detected '$($os.Caption)' (EditionID '$edition')."
        }
        Write-Log -Message "Detected '$($os.Caption)' (EditionID '$edition') build $build."
    }
}

New-Log -Path (Join-Path $env:SystemRoot 'Logs\Software') -Name 'Install-Windows11RSAT'
Write-Log -Message "Starting '$PSCommandPath'."
Assert-SupportedHost -MinimumBuild 22000 -ClientOnly

$offlineSourceAvailable = $false
if (Test-Path -LiteralPath $SourcePath -PathType Container) {
    $cabFiles = @(Get-ChildItem -LiteralPath $SourcePath -Filter '*.cab' -File -Recurse)
    if ($cabFiles.Count -gt 0) {
        $offlineSourceAvailable = $true
        Write-Log -Message "Found $($cabFiles.Count) CAB file(s) in offline source '$SourcePath'. Offline installation will be attempted first."
    }
    else {
        Write-Log -Category Warning -Message "No CAB files were found in offline source '$SourcePath'."
    }
}
else {
    Write-Log -Message "Offline source '$SourcePath' was not found."
}

if ($OfflineOnly -and -not $offlineSourceAvailable) {
    throw "OfflineOnly was specified, but no CAB files were found in '$SourcePath'."
}

$capabilityNames = @(
    'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'
    'Rsat.DHCP.Tools~~~~0.0.1.0'
)

$restartNeeded = $false
foreach ($capabilityName in $capabilityNames) {
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -eq 'Installed') {
        Write-Log -Message "Capability '$capabilityName' is already installed."
        continue
    }

    $installedOffline = $false
    if ($offlineSourceAvailable) {
        try {
            Write-Log -Message "Installing capability '$capabilityName' from '$SourcePath' with Windows Update access disabled."
            $result = Add-WindowsCapability `
                -Online `
                -Name $capabilityName `
                -Source $SourcePath `
                -LimitAccess

            if ($result.RestartNeeded) {
                $restartNeeded = $true
            }

            $capability = Get-WindowsCapability -Online -Name $capabilityName
            if ($capability.State -ne 'Installed') {
                throw "Capability state is '$($capability.State)' after the offline installation attempt."
            }

            $installedOffline = $true
            Write-Log -Message "Capability '$capabilityName' installed successfully from the offline source."
        }
        catch {
            if ($OfflineOnly) {
                throw "Offline installation of capability '$capabilityName' failed: $($_.Exception.Message)"
            }

            Write-Log -Category Warning -Message "Offline installation of capability '$capabilityName' failed: $($_.Exception.Message)"
            Write-Log -Category Warning -Message 'Falling back to the online Windows servicing source.'
        }
    }

    if ($installedOffline) {
        continue
    }

    try {
        Write-Log -Message "Installing capability '$capabilityName' from the online Windows servicing source."
        $result = Add-WindowsCapability `
            -Online `
            -Name $capabilityName

        if ($result.RestartNeeded) {
            $restartNeeded = $true
        }

        $capability = Get-WindowsCapability -Online -Name $capabilityName
        if ($capability.State -ne 'Installed') {
            throw "Capability state is '$($capability.State)' after the online installation attempt."
        }
    }
    catch {
        throw "Online installation of capability '$capabilityName' failed. Verify Windows Update access and optional-content source policy. $($_.Exception.Message)"
    }

    Write-Log -Message "Capability '$capabilityName' installed successfully from the online Windows servicing source."
}

Write-Log -Message "All requested RSAT capabilities are installed. Restart needed: $restartNeeded."

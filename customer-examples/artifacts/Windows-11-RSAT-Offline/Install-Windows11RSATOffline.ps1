<#
.SYNOPSIS
    Installs selected Windows 11 RSAT capabilities from a local Features on Demand source.

.DESCRIPTION
    Installs the Active Directory DS/LDS, Group Policy Management, and DHCP RSAT tools.
    The source must contain payloads from Windows 11 Features on Demand media that match
    the target operating system release, architecture, and installed language. LimitAccess
    prevents servicing from contacting Windows Update or WSUS.

.NOTES
    Run as Administrator or SYSTEM. This script is ASCII-only because it can be embedded in ARM.
#>

[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath 'Payload')
)

$ErrorActionPreference = 'Stop'
$Script:Name = 'Install-Windows11RSATOffline'
$Script:Log = $null

function New-Log {
    $logDirectory = Join-Path -Path $env:SystemRoot -ChildPath 'Logs\Software'
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    $Script:Log = Join-Path -Path $logDirectory -ChildPath "$Script:Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
}

function Write-Log {
    param(
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Category = 'Info',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t$Message"
    Add-Content -LiteralPath $Script:Log -Value $content -ErrorAction SilentlyContinue
    Write-Output $content
}

function Assert-SupportedHost {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM privileges are required.'
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This artifact supports only x64 Windows 11.'
    }

    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $productType = [int]$operatingSystem.ProductType
    $editionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction SilentlyContinue).EditionID
    $build = [Environment]::OSVersion.Version.Build

    # Windows 11 Enterprise multi-session reports ProductType 3 (server) with EditionID ServerRdsh.
    $isClient = $productType -eq 1
    $isMultiSession = $productType -eq 3 -and $editionId -eq 'ServerRdsh'
    if ((-not $isClient -and -not $isMultiSession) -or $build -lt 22000) {
        throw "This artifact supports only Windows 11 Enterprise and Windows 11 Enterprise multi-session. Detected '$($operatingSystem.Caption)' (ProductType $productType, EditionID '$editionId') build $build."
    }

    Write-Log -Message "Detected '$($operatingSystem.Caption)' (ProductType $productType, EditionID '$editionId') build $build."
}

New-Log
Write-Log -Message "Starting '$PSCommandPath'."
Assert-SupportedHost

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "The offline Features on Demand source directory was not found: '$SourcePath'."
}

$cabFiles = @(Get-ChildItem -LiteralPath $SourcePath -Filter '*.cab' -File -Recurse)
if ($cabFiles.Count -eq 0) {
    throw "No CAB files were found in the offline Features on Demand source: '$SourcePath'."
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

    Write-Log -Message "Installing capability '$capabilityName' from '$SourcePath' with Windows Update access disabled."
    $result = Add-WindowsCapability `
        -Online `
        -Name $capabilityName `
        -Source $SourcePath `
        -LimitAccess `
        -NoRestart

    if ($result.RestartNeeded) {
        $restartNeeded = $true
    }

    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne 'Installed') {
        throw "Capability '$capabilityName' has state '$($capability.State)' after installation."
    }

    Write-Log -Message "Capability '$capabilityName' installed successfully."
}

Write-Log -Message "All requested RSAT capabilities are installed. Restart needed: $restartNeeded."

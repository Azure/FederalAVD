<#
.SYNOPSIS
    Provisions Microsoft App Installer and Windows Package Manager (winget) for all future users.

.DESCRIPTION
    Installs the official Microsoft.DesktopAppInstaller MSIX bundle from the Microsoft winget-cli
    GitHub release by using its matching offline license and framework dependencies. The package is
    provisioned into the online Windows image so it is registered when new users sign in.

    This implementation is intended for image-build execution under SYSTEM. It mirrors the
    license-aware all-users provisioning performed by Repair-WinGetPackageManager -AllUsers without
    invoking that command, because the Microsoft.WinGet.Client repair command rejects SYSTEM.

.NOTES
    Stage these matching assets from one microsoft/winget-cli release beside this script:
      Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
      DesktopAppInstaller_Dependencies.zip
      DesktopAppInstaller_Dependencies.json
      *_License1.xml

    Add-AppxProvisionedPackage is called with -Regions all so the package survives sysprep.
#>

[CmdletBinding()]
param()

$Script:Name = 'Install-MicrosoftWinGet'
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $content = "[$timestamp] $Message"
    if ($env:SUPPRESS_FILELOG -ne '1') {
        Add-Content -Path $Script:Log -Value $content -ErrorAction SilentlyContinue
    }
    Write-Output $content
}

function New-Log {
    param([string]$Path)

    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
    $date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    $Script:Log = Join-Path $Path "$Script:Name-$date.log"
}

function Get-SingleFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Filter,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $files = @(Get-ChildItem -LiteralPath $Path -File -Filter $Filter -ErrorAction Stop)
    if ($files.Count -ne 1) {
        throw "Expected exactly one $Description matching '$Filter' in '$Path'; found $($files.Count)."
    }
    return $files[0]
}

function Get-AppxIdentity {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$PackageFile
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackageFile.FullName)
    try {
        $manifestEntry = $archive.Entries |
            Where-Object { $_.FullName -iin @('AppxManifest.xml', 'AppxMetadata/AppxBundleManifest.xml') } |
            Select-Object -First 1
        if ($null -eq $manifestEntry) {
            throw "No AppX manifest was found in '$($PackageFile.Name)'."
        }

        $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
        try {
            [xml]$manifest = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $identity = $manifest.SelectSingleNode("/*[local-name()='Package' or local-name()='Bundle']/*[local-name()='Identity']")
        if ($null -eq $identity -or [string]::IsNullOrWhiteSpace([string]$identity.Name) -or
            [string]::IsNullOrWhiteSpace([string]$identity.Version)) {
            throw "The AppX identity in '$($PackageFile.Name)' is incomplete."
        }

        $architecture = [string]$identity.ProcessorArchitecture
        if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = 'neutral' }
        return [pscustomobject]@{
            Name = [string]$identity.Name
            Version = [Version]([string]$identity.Version)
            Architecture = $architecture.ToLowerInvariant()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ProvisionedVersion {
    param([string]$IdentityName)

    $package = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like "$IdentityName`_*" } |
        Select-Object -First 1
    if ($null -eq $package) { return $null }
    if ($package.PackageName -match '_([0-9]+(?:\.[0-9]+){1,3})_') {
        return [Version]$Matches[1]
    }
    return $null
}

function Select-RequiredDependencies {
    param([System.IO.FileInfo[]]$DependencyPackages)

    $required = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($dependencyPackage in $DependencyPackages) {
        $identity = Get-AppxIdentity -PackageFile $dependencyPackage
        if ($identity.Architecture -notin @('x86', 'x64', 'neutral')) {
            Write-Log "Ignoring dependency for unsupported architecture '$($identity.Architecture)': $($dependencyPackage.Name)" | Out-Host
            continue
        }

        $installed = @(Get-AppxPackage -AllUsers -Name $identity.Name -ErrorAction SilentlyContinue |
            Where-Object {
                $installedArchitecture = if ($null -ne $_.Architecture) { $_.Architecture.ToString().ToLowerInvariant() } else { 'neutral' }
                $installedArchitecture -eq $identity.Architecture -or $identity.Architecture -eq 'neutral'
            } |
            Sort-Object Version -Descending |
            Select-Object -First 1)
        if ($installed.Count -gt 0 -and [Version]$installed[0].Version -ge $identity.Version) {
            Write-Log "Dependency already satisfied: $($identity.Name) $($identity.Architecture) $($installed[0].Version)" | Out-Host
            continue
        }

        Write-Log "Dependency required: $($identity.Name) $($identity.Architecture) $($identity.Version)" | Out-Host
        $required.Add($dependencyPackage)
    }
    return $required.ToArray()
}

New-Log (Join-Path $env:SystemRoot 'Logs')
Write-Log 'Install-MicrosoftWinGet: Starting'
Write-Log "Script location : $PSScriptRoot"

$bundle = Get-SingleFile -Path $PSScriptRoot `
    -Filter 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' `
    -Description 'App Installer bundle'
$dependencyArchive = Get-SingleFile -Path $PSScriptRoot `
    -Filter 'DesktopAppInstaller_Dependencies.zip' `
    -Description 'dependency archive'
$dependencyMetadata = Get-SingleFile -Path $PSScriptRoot `
    -Filter 'DesktopAppInstaller_Dependencies.json' `
    -Description 'dependency metadata file'
$license = Get-SingleFile -Path $PSScriptRoot `
    -Filter '*_License1.xml' `
    -Description 'App Installer license file'

try {
    $dependencyDefinition = Get-Content -LiteralPath $dependencyMetadata.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (@($dependencyDefinition.Dependencies).Count -eq 0) {
        throw 'Dependency metadata contains no dependency definitions.'
    }
}
catch {
    throw "Dependency metadata is not valid JSON: $($dependencyMetadata.FullName). $_"
}
try {
    [xml]$licenseXml = Get-Content -LiteralPath $license.FullName -Raw -ErrorAction Stop
    if ($null -eq $licenseXml.DocumentElement) { throw 'License XML has no document element.' }
}
catch {
    throw "App Installer license is not valid XML: $($license.FullName). $_"
}

$bundleIdentity = Get-AppxIdentity -PackageFile $bundle
if ($bundleIdentity.Name -ne 'Microsoft.DesktopAppInstaller') {
    throw "Unexpected bundle identity '$($bundleIdentity.Name)'; expected 'Microsoft.DesktopAppInstaller'."
}
Write-Log "Bundle         : $($bundle.Name)"
Write-Log "Bundle version : $($bundleIdentity.Version)"
Write-Log "License        : $($license.Name)"

$existingVersion = Get-ProvisionedVersion -IdentityName $bundleIdentity.Name
if ($null -ne $existingVersion -and $existingVersion -ge $bundleIdentity.Version) {
    Write-Log "SKIP: Provisioned App Installer version $existingVersion is equal to or newer than $($bundleIdentity.Version)."
    Write-Log 'Install-MicrosoftWinGet: Complete'
    exit 0
}

$dependencyRoot = Join-Path $env:TEMP "Microsoft-WinGet-Dependencies-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -Path $dependencyRoot -ItemType Directory -Force | Out-Null
    Expand-Archive -LiteralPath $dependencyArchive.FullName -DestinationPath $dependencyRoot -Force
    $dependencyPackages = @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Extension.ToLowerInvariant() -in @('.appx', '.msix') })
    if ($dependencyPackages.Count -eq 0) {
        throw "No APPX or MSIX dependency packages were found in '$($dependencyArchive.Name)'."
    }
    $dependencyIdentities = @($dependencyPackages | ForEach-Object {
        $identity = Get-AppxIdentity -PackageFile $_
        [pscustomobject]@{
            File = $_
            Name = $identity.Name
            Version = $identity.Version
            Architecture = $identity.Architecture
        }
    })
    foreach ($definition in $dependencyDefinition.Dependencies) {
        foreach ($requiredArchitecture in @('x86', 'x64')) {
            $matchingDependency = @($dependencyIdentities | Where-Object {
                $_.Name -eq [string]$definition.Name -and
                $_.Version -eq [Version]([string]$definition.Version) -and
                $_.Architecture -eq $requiredArchitecture
            })
            if ($matchingDependency.Count -ne 1) {
                throw "Dependency archive must contain exactly one $($definition.Name) $($definition.Version) $requiredArchitecture package; found $($matchingDependency.Count)."
            }
        }
    }
    Write-Log "Validated $(@($dependencyDefinition.Dependencies).Count) dependency definition(s) against the archive."
    $requiredDependencies = @(Select-RequiredDependencies -DependencyPackages $dependencyPackages)

    $provisionParameters = @{
        Online = $true
        PackagePath = $bundle.FullName
        LicensePath = $license.FullName
        Regions = 'all'
        ErrorAction = 'Stop'
    }
    if ($requiredDependencies.Count -gt 0) {
        $provisionParameters.DependencyPackagePath = @($requiredDependencies | Select-Object -ExpandProperty FullName)
    }

    Write-Log "Provisioning App Installer with $($requiredDependencies.Count) required dependency package(s)..."
    Add-AppxProvisionedPackage @provisionParameters | Out-Null

    $verifiedPackage = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like "$($bundleIdentity.Name)`_*" } |
        Select-Object -First 1
    $verifiedVersion = Get-ProvisionedVersion -IdentityName $bundleIdentity.Name
    if ($null -eq $verifiedPackage -or $null -eq $verifiedVersion -or $verifiedVersion -lt $bundleIdentity.Version) {
        throw "App Installer $($bundleIdentity.Version) was not found in the provisioned package store after installation."
    }

    if ($verifiedPackage.PackageName -match '^(.+?)_[\d\.]+_[^_]+__([^_]+)$') {
        $packageFamilyName = "$($Matches[1])_$($Matches[2])"
        $deprovisionedPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$packageFamilyName"
        if (Test-Path -LiteralPath $deprovisionedPath) {
            Remove-Item -LiteralPath $deprovisionedPath -Recurse -Force -ErrorAction Stop
            Write-Log "Cleared deprovisioned record: $packageFamilyName"
        }
    }

    Write-Log "Provisioned App Installer version: $verifiedVersion"
    Write-Log 'WinGet is provisioned for registration when each new user signs in.'
    Write-Log 'Install-MicrosoftWinGet: Complete'
}
finally {
    Remove-Item -LiteralPath $dependencyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0

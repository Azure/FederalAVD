# Microsoft WinGet

## Overview

This artifact provisions Microsoft App Installer, which includes Windows Package Manager (`winget`),
for all users of a Windows image. It uses the official assets published together in one
[`microsoft/winget-cli` GitHub release](https://github.com/microsoft/winget-cli/releases/latest):

- `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`
- `DesktopAppInstaller_Dependencies.zip`
- `DesktopAppInstaller_Dependencies.json`
- `*_License1.xml`

App Installer is deliberately separate from the `BuiltIn-UWP-Apps` artifact. Unlike ordinary Store
apps, its supported all-users provisioning path requires the release's matching offline license.

## Supported servicing paths

- On normal Windows 10 and Windows 11 desktops, Microsoft Store services App Installer automatically.
- Windows Server 2025 can receive App Installer through Windows Update.
- In an interactive administrator session, `Repair-WinGetPackageManager -AllUsers` is Microsoft's
  supported bootstrap and repair command.
- Azure Image Builder runs customizations as SYSTEM. The repair command rejects SYSTEM, so this
  artifact performs the equivalent license-aware offline provisioning directly.

Do not run `winget upgrade Microsoft.AppInstaller` from an image-build customization. That command
requires an already usable per-user WinGet registration and is not an all-users image provisioning
mechanism.

## Setup

### Standalone transfer builder

The `_build` folder contains a connected-workstation builder that resolves all four assets from one
stable official release, verifies GitHub-published SHA256 digests when available, copies the runtime
installer, and creates a transfer-ready artifact:

```powershell
cd C:\repos\FederalAVD\customer-examples\artifacts\Microsoft-WinGet\_build

.\Build-MicrosoftWinGet.ps1 `
    -OutputPath 'C:\AirGapTransfer\Microsoft-WinGet.zip'
```

The latest stable release is selected by default. To create a reproducible package from a specific
release, pass its exact tag:

```powershell
.\Build-MicrosoftWinGet.ps1 `
    -ReleaseTag 'v1.29.290' `
    -OutputPath 'C:\AirGapTransfer'
```

The generated ZIP contains `Install-MicrosoftWinGet.ps1`, all four matching release assets, and a
`transfer-manifest.json` containing the release tag, asset names, sizes, and SHA256 hashes. The
builder remains under `_build` and is not included in the runtime artifact.

### 1. Copy the artifact

```powershell
Copy-Item -Recurse -Path "customer-examples\artifacts\Microsoft-WinGet" `
    -Destination "customer\artifacts\"
```

### 2. Add the grouped download definition

Copy the `MicrosoftWinGet` entry from
`customer-examples/parameters/imageManagement/downloads.json` into
`customer/parameters/imageManagement/downloads.json`.

The entry resolves all four exact asset patterns from one latest official GitHub release and
downloads them directly into the staged `Microsoft-WinGet` artifact folder. Do not mix assets from
different releases.

The connected downloads are equivalent to resolving these release assets:

```powershell
$release = Invoke-RestMethod `
    -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
    -Method Get
$assetPatterns = @(
    'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    'DesktopAppInstaller_Dependencies.zip'
    'DesktopAppInstaller_Dependencies.json'
    '*_License1.xml'
)
foreach ($pattern in $assetPatterns) {
    $asset = @($release.assets | Where-Object name -Like $pattern)
    if ($asset.Count -ne 1) { throw "Expected one release asset matching '$pattern'." }
    Invoke-WebRequest -Uri $asset[0].browser_download_url `
        -OutFile (Join-Path 'customer\artifacts\Microsoft-WinGet' $asset[0].name)
}
```

### 3. Package or upload

```powershell
cd deployments
.\Update-ImageArtifacts.ps1 -PackageOnly -OutputPath 'C:\AirGapTransfer'
```

For a connected Azure environment, use the normal storage account parameters instead of
`-PackageOnly`. The result is `Microsoft-WinGet.zip`.

### 4. Add the customization

Run this artifact before `BuiltIn-UWP-Apps` when both are used:

```json
{
    "name": "Microsoft-WinGet",
    "blobNameOrUri": "Microsoft-WinGet.zip"
}
```

## Installation behavior

`Install-MicrosoftWinGet.ps1`:

1. Requires exactly one bundle, dependency archive, dependency metadata file, and license.
2. Validates the bundle identity as `Microsoft.DesktopAppInstaller` and validates the JSON and XML.
3. Expands the official dependencies archive.
4. Selects x86, x64, and neutral dependencies that are not already satisfied by the image.
5. Skips installation when an equal or newer App Installer version is already provisioned.
6. Provisions the bundle with `Add-AppxProvisionedPackage -Online -LicensePath ... -Regions all`.
7. Verifies the resulting package in the provisioned package store.

The script does not register App Installer for the SYSTEM account. Windows registers the
provisioned package when each new user signs in, which is the required golden-image behavior.

## Air-gapped preparation

`GitHubRepo` downloads require public GitHub access and must run only on a connected preparation
workstation. For Secret or Top Secret environments:

1. Download all four assets from the same approved WinGet release on a connected system.
2. Verify the release source and file hashes according to the organization's transfer procedure.
3. Place the files beside `Install-MicrosoftWinGet.ps1` in
   `customer/artifacts/Microsoft-WinGet` on the disconnected management system.
4. Run `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources` to package and upload the pre-staged
   artifact without contacting GitHub.

No download occurs from the image-build VM.

The standalone builder is the recommended way to perform steps 1 and 2 because it resolves one
release once, requires exactly one match for every asset, and validates published digests.

## Troubleshooting

| Symptom | Cause | Resolution |
| --- | --- | --- |
| Expected exactly one asset | An asset is missing, duplicated, or retained from an older release | Clear payload files and stage all four assets from one release |
| Unexpected bundle identity | The staged bundle is not Microsoft App Installer | Download the exact official bundle name from `microsoft/winget-cli` |
| License or dependency validation fails | Assets came from different or incomplete downloads | Re-stage the complete release asset set |
| Provisioning fails with a dependency error | A required framework is missing or incompatible | Confirm the matching dependencies ZIP is present and rebuild the artifact |
| WinGet is unavailable to SYSTEM immediately after provisioning | App Installer is provisioned, not registered for SYSTEM | Validate from a new user session on a deployed test VM |

# BuiltIn-UWP-Apps

## Overview

This artifact **upgrades existing image-provisioned** Windows UWP applications and codec extensions
by default. Staged apps absent from the provisioned image are skipped; use `-InstallMissing` to
add them intentionally. Apps are downloaded via `winget` on the connected preparation system,
then provisioned into the image using local packages without requiring a Store connection.

Presence is determined by `Get-AppxProvisionedPackage`, not each user's installed apps.
This respects apps removed from the image baseline, but does **not** enforce an individual user's
uninstall choice for an app that remains provisioned. It is not a per-user updater.

## Why offline provisioning?

AVD image build VMs typically have restricted outbound internet access and run in a SYSTEM context
with no active user session, which prevents Store-based auto-reinstallation. Provisioning the
packages offline bakes the apps into the image component store so they appear in every user
profile from first login -- no Store connection, no per-user download.

## Critical prerequisite: provisioning must use `-Regions all`

For provisioned apps to survive `sysprep /generalize` and appear for users on deployed session
hosts, `Add-AppxProvisionedPackage` **must** be called with `-Regions all`. Without this
parameter, Windows only provisions the app for Start layout pinning scenarios and removes it
during sysprep — moving the package folder to `WindowsApps\Deleted` and logging event ID 472.

The script passes `-Regions all` automatically. You do not need to pass any special argument.

Reference: Microsoft internal support article (June 2026) — "Windows Store apps are not
retained after sysprep".

## Apps included

| Folder | App | Winget Store ID |
| --- | --- | --- |
| `Calculator` | Windows Calculator | `9WZDNCRFHVN5` |
| `Paint` | Microsoft Paint | `9PCFS5B6T72H` |
| `SnippingTool` | Snipping Tool | `9MZ95KL8MR0L` |
| `Notepad` | Notepad | `9MSMLRH6LZF3` |
| `Clipchamp` | Clipchamp | `9P1J8S7CCWWT` |
| `Photos` | Microsoft Photos | `9WZDNCRFJBH4` |
| `StickyNotes` | Sticky Notes | `9NBLGGH4QGHW` |
| `Terminal` | Windows Terminal | `9N0DX20HK701` |
| `VP9VideoExtensions` | VP9 Video Extensions | `9N4D0MSMP0PT` |
| `WebMediaExtensions` | Web Media Extensions | `9N5TDP8VCMHS` |
| `WebpImageExtension` | WebP Image Extension | `9PG2DK419DRG` |
| `AV1VideoExtension` | AV1 Video Extension | `9MVZQVXJBQ9V` |
| `MPEG2VideoExtension` | MPEG-2 Video Extension | `9N95Q1ZZPMH4` |
| `HEVCVideoExtension` | HEVC Video Extension (appropriate licensing required) | `9N4WGH0Z6VHQ` |
| `HEIFImageExtension` | HEIF Image Extension | `9PMMSR1CGPWG` |

Add or remove entries from `downloads.json` to change which apps are staged through the repository
pipeline. To build a standalone transfer zip from an explicit array of Store IDs, use the local
builder described below.

The AVC Encoder Video Extension (`9PB0TRCNRHFX`) is intentionally excluded. Microsoft Store
resolves the product ID but reports that the package does not support download, so it cannot be
staged with `winget download`. Azure Virtual Desktop RDP hardware encoding does not depend on this
package; RDP uses the supported GPU driver directly.

The HEIF Image Extension uses the AV1 Video Extension to display AVIF images. Displaying HEIC and
other HEVC-compressed HEIF images also requires the separately licensed HEVC Video Extensions
package. The downloads example includes `HEVCVideoExtension` using product ID `9N4WGH0Z6VHQ`;
remove that entry unless your organization is licensed to deploy it. Package availability does
not grant installation or redistribution rights. `Update-ImageArtifacts.ps1` tries WinGet first,
then its direct Microsoft Store fallback for this preserve-layout entry. For connected staging,
run the repository pipeline below; transfer the resulting approved ZIP through your authorized
offline process rather than downloading from inside the enclave.

Microsoft App Installer and Windows Package Manager are intentionally excluded. App Installer
requires its matching offline license for supported all-users provisioning and is handled by the
separate `Microsoft-WinGet` artifact.

## Artifact folder structure

The `BuiltIn-UWP-Apps` artifact folder is populated at runtime by `Update-ImageArtifacts.ps1`.
You do not need to place any files in it manually.

After the script runs, the staged layout looks like:

```text
BuiltIn-UWP-Apps\
    Install-BuiltinUwpApps.ps1          <- main provisioning script (from this folder)
    Calculator\
        Microsoft.WindowsCalculator_<ver>_neutral_~_8wekyb3d8bbwe.msixbundle
    Paint\
        Microsoft.Paint_<ver>_neutral_~_8wekyb3d8bbwe.msixbundle
    SnippingTool\
        ...
    ...
    SharedDependencies\                  <- shared framework packages (deduped by Update-ImageArtifacts.ps1)
        Microsoft.VCLibs.140.00.UWPDesktop_<ver>_x64__8wekyb3d8bbwe.appx
        Microsoft.UI.Xaml.2.8_<ver>_x64__8wekyb3d8bbwe.appx
        ...
```

`winget download` places framework packages (VCLibs, WinAppSDK, UI.Xaml, etc.) into a
`Dependencies\` subfolder inside each app folder. `Update-ImageArtifacts.ps1` then runs
`Optimize-SharedDependencies`, which consolidates those into a single `SharedDependencies\`
folder at the `BuiltIn-UWP-Apps\` root and removes the per-app `Dependencies\` folders.
`Install-BuiltinUwpApps.ps1` reads dependencies exclusively from `SharedDependencies\`.

## Setup

### 1. Copy this artifact folder

```powershell
Copy-Item -Recurse -Path "customer-examples\artifacts\BuiltIn-UWP-Apps" `
          -Destination "customer\artifacts\"
```

### 2. Copy the example downloads file

If you do not already have a customer downloads file, copy the complete example into the
auto-discovered location:

```powershell
New-Item -Path "customer\parameters\imageManagement" -ItemType Directory -Force | Out-Null
Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\downloads.json"
```

The downloads entries for each app use the `WingetPreserveLayout` flag, which tells
`Update-ImageArtifacts.ps1` to preserve the native folder layout produced by
`winget download` instead of renaming the file. This is required for MSIX/MSIXBUNDLE packages
that must keep their original filenames for `Add-AppxProvisionedPackage` to work correctly.

If `customer/parameters/imageManagement/downloads.json` already contains customized entries,
do not overwrite it. Merge the entries with `"WingetPreserveLayout": true` and
`DestinationFolders` beginning with `BuiltIn-UWP-Apps\` from the example file into your existing
file.

### 3. Download and package the artifact

#### Standalone transfer builder

For a combined UWP/WinGet/Teams-prerequisite transfer ZIP, see the
[connected builder and gated release workflow](../../../docs/air-gapped-clouds.md#combined-prerequisite-transfer-zip).
It reuses this builder, supports a subset of the existing app selection, excludes HEVC, and keeps
`BuiltIn-UWP-Apps.zip` as a separate inner artifact.
Large combined releases use hash-verified transport parts that must be reassembled before
extracting the outer ZIP. Shared framework dependencies remain included for offline provisioning.

The `_build` folder contains a connected-workstation builder that does not depend on
`Update-ImageArtifacts.ps1` or `downloads.json`. By default it includes every Store ID in the table
above except the separately licensed HEVC extension. The standalone builder is WinGet-only;
use `Update-ImageArtifacts.ps1` for HEVC staging with the direct Store fallback.
It downloads the packages with `winget`, keeps the best x64-compatible package variant,
removes Arm dependencies, deduplicates shared framework packages, and creates one zip for transfer:

```powershell
cd C:\repos\FederalAVD\customer-examples\artifacts\BuiltIn-UWP-Apps\_build

.\Build-BuiltinUwpApps.ps1 `
    -OutputPath 'C:\AirGapTransfer\BuiltIn-UWP-Apps.zip'
```

Pass `-AppStoreIds` to build a subset instead:

```powershell
.\Build-BuiltinUwpApps.ps1 `
    -AppStoreIds @(
        '9WZDNCRFHVN5', # Calculator
        '9PCFS5B6T72H', # Paint
        '9MZ95KL8MR0L'  # Snipping Tool
    ) `
    -OutputPath 'C:\AirGapTransfer\BuiltIn-UWP-Apps.zip'
```

Known IDs use the friendly folder names in the table above. Unknown valid Store IDs use the ID as
the app folder name, which is still compatible with the installer. Override a folder name when
needed:

```powershell
.\Build-BuiltinUwpApps.ps1 `
    -AppStoreIds @('9WZDNCRFHVN5') `
    -AppFolderNames @{ '9WZDNCRFHVN5' = 'Calculator' } `
    -OutputPath 'C:\AirGapTransfer'
```

The builder itself is nested under `_build` and is not included in the generated zip, so
`Invoke-Customization.ps1` cannot select it. The runtime installer also ignores underscore-prefixed
directories when enumerating app payloads.

On the disconnected network, upload `BuiltIn-UWP-Apps.zip` to the artifacts container or extract it
to `customer\artifacts\BuiltIn-UWP-Apps` and run the normal package/upload process with downloading
disabled.

#### Repository-wide package builder

To create `BuiltIn-UWP-Apps.zip` locally without an Azure subscription or storage account:

```powershell
cd C:\repos\FederalAVD\deployments

.\Update-ImageArtifacts.ps1 `
    -PackageOnly `
    -OutputPath "C:\AirGapTransfer"
```

This downloads each app package via `winget download`, deduplicates shared dependency packages
into `SharedDependencies\`, then writes `C:\AirGapTransfer\BuiltIn-UWP-Apps.zip`. This is the
recommended workflow when preparing the zip for transfer to an air-gapped network.

To package and upload directly to an existing artifacts storage account instead:

```powershell
cd C:\repos\FederalAVD\deployments

.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "<your-storage-account>" `
    -ResourceGroupName "<your-resource-group>"
```

The storage-backed command runs the same packaging pipeline, then uploads the zip to the
`artifacts` blob container.

### 4. Add the artifact to your image build customizations

In your image build parameter file, add `BuiltIn-UWP-Apps` to the `customizations` array.
No arguments are needed for the default upgrade-only behavior:

```json
{
    "name": "BuiltIn-UWP-Apps",
    "uri": "BuiltIn-UWP-Apps.zip"
}
```

To intentionally provision staged apps that are missing from the image, opt in:

```json
{
    "name": "BuiltIn-UWP-Apps",
    "uri": "BuiltIn-UWP-Apps.zip",
    "arguments": "-InstallMissing"
}
```

For direct execution from a copied, populated customer artifact folder:

```powershell
.\Install-BuiltinUwpApps.ps1                 # Upgrade existing provisioned apps only
.\Install-BuiltinUwpApps.ps1 -InstallMissing # Also add missing staged apps
```

This changes the previous install-or-update default. Existing prebuilt ZIPs keep their embedded
installer's behavior; rebuild and re-upload the artifact to adopt the new default.

## What Install-BuiltinUwpApps.ps1 does

1. **Snapshots** all currently provisioned packages before any changes are made (used for
   change logging).
2. **Iterates** each app subfolder (skipping `SharedDependencies\`).
3. **Selects** the best main package: highest version first, then bundle format preferred over
   single-arch package, then largest file as a tiebreaker.
4. **Checks the exact app identity** against the current provisioned image. Skips absent apps
   unless `-InstallMissing` is supplied, and always skips equal or newer versions.
5. **Resolves dependencies** from the `SharedDependencies\` folder at the artifact root;
   deduplicates by package family, keeping the highest version.
6. **Provisions** via `Add-AppxProvisionedPackage -Online -SkipLicense -Regions all`.
        - Detects MSIX/APPX bundles that winget saved with a single-package extension and corrects
            `.msix` to `.msixbundle` or `.appx` to `.appxbundle` before provisioning.
        - The `-Regions all` parameter is required for the provisioned package to survive sysprep.
        - First attempt: no explicit dependencies (the OS component store satisfies frameworks on a
            modern Windows 11 image). This avoids error `0xc1570118` that occurs when passing explicit
            dependency packages that conflict with already-registered OS versions.
        - If the first attempt fails and staged dependencies are available, retries with explicit
            `-DependencyPackagePath`.
7. **Logs a change summary** table at the end showing before/after versions for each app.
   Intentionally skipped absent apps do not fail the image health check. Inventory lookup errors
   stop execution rather than being treated as an empty image.

The existing remove-before-add update sequence remains unchanged. If provisioning fails after
removing an old entry, the script reports failure; do not publish that image. Restore the approved
package or explicitly use `-InstallMissing` when retrying an app that is now absent.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| App folder skipped with "No package file found" | `winget download` failed or the Store ID is wrong | Check winget output in `Update-ImageArtifacts.ps1` log; verify the WingetId in `downloads.json` |
| `0xc1570118 APPX_E_PREREQUISITE_NOT_MET` | Explicit dependencies conflict with OS-registered versions | The two-attempt provisioning handles this automatically; if it persists, the staged dependency version may be older than what the OS has -- update your artifacts |
| App shows "up-to-date" unexpectedly | A newer version was already provisioned from a previous build | This is correct behavior; the script never downgrades |
| App is skipped as "not provisioned" | The app is absent from the image-wide provisioned baseline | Intentional default; use `-InstallMissing` only if you want to add it |
| Before-version shows "(not present)" | The app was absent from the image | It is skipped by default, or installed intentionally with `-InstallMissing` |
| App installs but does not appear for users (image build or live host) | `-Regions all` not passed to `Add-AppxProvisionedPackage`; sysprep removes the package (event ID 472) | Confirmed fixed in this script version. Re-upload the artifact (`Update-ImageArtifacts.ps1`) and rebuild the image |
| App installs but does not appear for users (live host) | App was provisioned after user profiles were created | `Add-AppxProvisionedPackage` only applies to new user sessions. Existing profiles need `Add-AppxPackage` per user |

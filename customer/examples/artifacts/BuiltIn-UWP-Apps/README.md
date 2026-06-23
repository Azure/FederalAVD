# BuiltIn-UWP-Apps

## Overview

This artifact provisions built-in Windows UWP applications and codec extensions for all users on
an AVD image. Apps are downloaded offline via `winget` during the artifact update phase, then
provisioned into the image using `Add-AppxProvisionedPackage` so every user who signs in after
imaging has the apps available without needing a Store connection.

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
|--------|-----|-----------------|
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

Add or remove entries from `downloads.json` to change which apps are staged and provisioned.

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
Copy-Item -Recurse -Path "customer\examples\artifacts\BuiltIn-UWP-Apps" `
          -Destination "customer\artifacts\"
```

### 2. Add the downloads entries to your downloads.json

The downloads entries for each app use the `WingetPreserveLayout` flag, which tells
`Update-ImageArtifacts.ps1` to preserve the native folder layout produced by
`winget download` instead of renaming the file. This is required for MSIX/MSIXBUNDLE packages
that must keep their original filenames for `Add-AppxProvisionedPackage` to work correctly.

If you have already copied
`customer/examples/parameters/imageManagement/downloads.json` to
`customer/parameters/imageManagement/downloads.json`, the UWP entries are already included.
Otherwise, add the entries from the examples file manually. The relevant entries are the ones
with `"WingetPreserveLayout": true` and `DestinationFolders` beginning with `BuiltIn-UWP-Apps\`.

```json
"WindowsCalculator": {
    "Description": "Windows Calculator - built-in UWP app provisioned for all users",
    "WingetId": "9WZDNCRFHVN5",
    "WingetPreserveLayout": true,
    "DestinationFolders": [ "BuiltIn-UWP-Apps\\Calculator" ]
},
"MicrosoftPaint": {
    "Description": "Microsoft Paint - built-in UWP app provisioned for all users",
    "WingetId": "9PCFS5B6T72H",
    "WingetPreserveLayout": true,
    "DestinationFolders": [ "BuiltIn-UWP-Apps\\Paint" ]
}
```

See `customer/examples/parameters/imageManagement/downloads.json` for the full set.

### 3. Download and upload the artifacts

```powershell
cd C:\repos\FederalAVD\deployments

.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "<your-storage-account>" `
    -ResourceGroupName "<your-resource-group>"
```

This downloads each app package via `winget download`, deduplicates shared dependency packages
into `SharedDependencies\`, then zips and uploads the entire `BuiltIn-UWP-Apps` folder as a
single `BuiltIn-UWP-Apps.zip` artifact.

### 4. Add the artifact to your image build customizations

In your image build parameter file, add `BuiltIn-UWP-Apps` to the `customizations` array.
No special arguments are needed — the script handles prerequisites automatically:

```json
{
    "name": "BuiltIn-UWP-Apps",
    "uri": "[parameters('artifactsContainerUri')]BuiltIn-UWP-Apps.zip"
}
```

## What Install-BuiltinUwpApps.ps1 does

1. **Snapshots** all currently provisioned packages before any changes are made (used for
   change logging).
2. **Iterates** each app subfolder (skipping `SharedDependencies\`).
3. **Selects** the best main package: highest version first, then bundle format preferred over
   single-arch package, then largest file as a tiebreaker.
4. **Skips** the app if an equal or newer version is already provisioned.
5. **Resolves dependencies** from the `SharedDependencies\` folder at the artifact root;
   deduplicates by package family, keeping the highest version.
6. **Provisions** via `Add-AppxProvisionedPackage -Online -SkipLicense -Regions all`.
   - The `-Regions all` parameter is required for the provisioned package to survive sysprep.
   - First attempt: no explicit dependencies (the OS component store satisfies frameworks on a
     modern Windows 11 image). This avoids error `0xc1570118` that occurs when passing explicit
     dependency packages that conflict with already-registered OS versions.
   - If the first attempt fails and staged dependencies are available, retries with explicit
     `-DependencyPackagePath`.
7. **Logs a change summary** table at the end showing before/after versions for each app.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| App folder skipped with "No package file found" | `winget download` failed or the Store ID is wrong | Check winget output in `Update-ImageArtifacts.ps1` log; verify the WingetId in `downloads.json` |
| `0xc1570118 APPX_E_PREREQUISITE_NOT_MET` | Explicit dependencies conflict with OS-registered versions | The two-attempt provisioning handles this automatically; if it persists, the staged dependency version may be older than what the OS has -- update your artifacts |
| App shows "up-to-date" unexpectedly | A newer version was already provisioned from a previous build | This is correct behavior; the script never downgrades |
| Before-version shows "(not present)" | The app was genuinely new on this image | Correct; on subsequent runs the before-version will reflect the previously provisioned version |
| App installs but does not appear for users (image build or live host) | `-Regions all` not passed to `Add-AppxProvisionedPackage`; sysprep removes the package (event ID 472) | Confirmed fixed in this script version. Re-upload the artifact (`Update-ImageArtifacts.ps1`) and rebuild the image |
| App installs but does not appear for users (live host) | App was provisioned after user profiles were created | `Add-AppxProvisionedPackage` only applies to new user sessions. Existing profiles need `Add-AppxPackage` per user |

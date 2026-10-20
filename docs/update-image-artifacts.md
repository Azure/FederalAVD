[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

> **📚 Conceptual Guide:** For how the artifact system works, how artifacts are executed during image builds and session host deployments, and how to create custom artifact packages, see the [Artifacts and Image Management Guide](artifacts-guide.md).

# Update-ImageArtifacts.ps1 Script Guide

## Overview

`Update-ImageArtifacts.ps1` is a PowerShell script that downloads the latest software sources, stages artifacts from `customer/artifacts/` (overlaid on any repo-provided artifacts in `deployments/shared/artifacts/`), packages them as zip files, and either uploads them to the image management artifacts storage account or writes them to a local folder. Run it whenever you want to refresh what is available to image build deployments — for example, after adding a new software package or after a new version is released.

> **Infrastructure vs. Artifacts:** This script does **not** deploy any Azure resources. To upload artifacts, deploy the imageManagement template first (see [imageManagement README](../deployments/imageManagement/README.md) or [Quick Start Step 2](quick-start.md#step-2-deploy-image-management-resources)), then use this script to populate the storage account. Alternatively, use `Deploy-ImageManagement.ps1 -UpdateArtifacts` to do both in one step. To create packages locally without an Azure subscription or storage account, use `-PackageOnly -OutputPath <folder>`.

To publish selected uploaded ZIP files as Azure Compute Gallery VM Applications, continue with the
[VM Application publishing guide](vm-applications.md). Uploading artifacts alone does not publish
applications.

## Notes

- In air-gapped clouds (Secret/Top Secret), the script selects the target-cloud base manifest and downloads from its endpoints when reachable. The standard high-side workflow needs **no customer `downloads.json`**; use `-CustomerDownloadsMode None` to ignore customer download overlays without disabling base downloads or customer artifacts. Pre-stage manual prerequisites and complete selected customer packages under `customer/artifacts/` (or `<CustomerRootPath>\artifacts\`). See [Prepare the Low-to-High Transfer Bundle](air-gapped-clouds.md#prepare-the-low-to-high-transfer-bundle).
- `-PackageOnly` output is a **low-side working directory**, not a transfer bundle. It uses the public base manifest and can include public OneDrive, Teams, Office Deployment Tool, AVD Agent/Boot Loader, and FSLogix outputs. Do not transfer the entire directory or use `*.zip`; explicitly select approved customer packages and manual prerequisites, leaving public base Microsoft files on low.
- Use `-DeleteExistingBlobs` for a clean upload when removing old packages.
- Use `-CustomerRootPath <path>` to point to a folder outside the repo zip (e.g., a persistent share or pipeline workspace). Pre-staged artifact files go in `<CustomerRootPath>\artifacts\`; the downloads parameter file goes in `<CustomerRootPath>\parameters\imageManagement\`.
- Use `-CustomerArtifactsMode None` to exclude customer artifacts, or `-CustomerDownloadsMode None` to ignore only customer download entries. The latter still packages customer artifacts and processes the cloud-selected base downloads.
- To merge customer-owned optional downloads, place `downloads.json` in `<CustomerRootPath>\parameters\imageManagement\`; the script discovers it automatically.

## What This Script Does

Three sequential phases:

1. **Download** — Fetches the latest versions of software from the internet using the downloads parameter file (skipped with `-SkipDownloadingNewSources` or when no downloads file exists)
2. **Package** — Compresses each subdirectory in the staged artifacts view (repo base in `deployments/shared/artifacts/` overlaid by `customer/artifacts/`)
3. **Upload** — Uploads all packaged artifacts to the `artifacts` blob container in the storage account

## Prerequisites

### Required Permissions

- **Storage Blob Data Contributor** on the image management artifacts storage account — required because the storage account disables shared key access (Zero Trust). `Contributor` or `Owner` on the subscription or resource group does **not** grant blob data access. See [full explanation](hostpool-deployment.md#security-prerequisites-optional).

### Required Tools

- PowerShell 5.1 or PowerShell 7+
- Azure PowerShell Az module for upload modes
- Active Azure login (`Connect-AzAccount`) for upload modes; not required for `-PackageOnly`

### Required Files

Base downloads parameter files are in `deployments/shared/data/` and are selected automatically based on the connected Azure environment — no action needed:

  - `deployments/shared/data/public.downloads.parameters.json` (commercial / government)
  - `deployments/shared/data/secret.downloads.parameters.json` (Azure Secret)
  - `deployments/shared/data/topsecret.downloads.parameters.json` (Azure Top Secret)

On a **connected preparation system**, to download optional software (e.g., PowerShell 7, VS Code,
LGPO, Git), place a customer-owned downloads file at
`customer/parameters/imageManagement/downloads.json`. A ready-to-use example that covers a broad
set of common packages is provided at:
  - `customer-examples/parameters/imageManagement/downloads.json`

Copy it to the auto-discovered location:

```powershell
Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\" -Force
```

Select only the entries needed for your workload. For low-to-high handoff, this customer manifest
stays on low; transfer only selected approved complete packages, not this file or the whole
low-side customer directory. The repository's base manifests stay in the repository on high.
A separately maintained high-side overlay is optional only for deliberate approved internal source
overrides; it is not required for pre-staged customer packages.

A minimal reference file with only the repo-required entries is also available at:
  - `deployments/imageManagement/parameters/sample-optional.downloads.parameters.json`

## Parameters

Choose one of three parameter sets. The two upload modes identify a storage account by either its full resource ID or its name and resource group. The local package mode requires no Azure resources or login.

### Parameter Set 1: By Resource ID (default)

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| **StorageAccountResourceId** | String | **Yes** | Full resource ID of the artifacts storage account. Obtain from the `artifactsStorageAccountResourceId` imageManagement deployment output. |

### Parameter Set 2: By Name

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| **StorageAccountName** | String | **Yes** | Name of the artifacts storage account. |
| **ResourceGroupName** | String | **Yes** | Resource group containing the storage account. |

### Parameter Set 3: Local Package

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| **PackageOnly** | Switch | **Yes** | Package artifacts locally and skip all Azure context, storage account, and upload operations. |
| **OutputPath** | String | **Yes** | Folder that receives the generated artifact files. Existing files with the same names are overwritten. |

Local package mode uses the public downloads manifest because it runs on an internet-connected
system without an Azure cloud context. The download, preserve-layout, dependency deduplication,
and compression behavior is otherwise identical to the upload modes.
There is no target-cloud selection in this mode. Public base Microsoft outputs are not approved
Secret/Top Secret packages; obtain the target-cloud versions within high instead.

### Common Parameters (all sets)

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| **DeleteExistingBlobs** | Switch | `$false` | Delete all existing blobs in the container before uploading. Use for a clean refresh rather than incremental update. |
| **SkipDownloadingNewSources** | Switch | `$false` | Skip all source downloads. On high, use only after every required target-cloud file is staged through approved internal sources. |
| **CustomerDownloadsMode** | String | `Merge` | `None` ignores the customer download overlay but retains base downloads and customer artifacts. Recommended on high. |
| **TempDir** | String | `$Env:Temp` | Temporary directory for packaging. Use a path on a high-performance drive for large artifact sets. |

## Usage Examples

### Create Packages Locally Without Azure

Download the latest sources and write generated artifact files to a low-side working folder.
No Azure PowerShell login, subscription, or storage account is required:

```powershell
cd C:\repos\FederalAVD\deployments

.\Update-ImageArtifacts.ps1 `
    -PackageOnly `
    -OutputPath "C:\FederalAVD-PackageOutput"
```

For preserve-layout UWP/MSIX entries, this runs the same package selection, architecture pruning,
and shared dependency deduplication used by storage upload mode. For example, the
`BuiltIn-UWP-Apps` artifact is written as `C:\FederalAVD-PackageOutput\BuiltIn-UWP-Apps.zip`.

For air-gapped use, copy only the explicit approved file allowlist into a separate transfer bundle.
Do not copy this entire output directory or select every ZIP: the public base `FSLogix.zip` is not
a customer artifact. Leave public OneDrive, Teams, ODT, AVD Agent/Boot Loader, and FSLogix outputs on
low, including any copies embedded in customer packages. Follow
[Prepare the Low-to-High Transfer Bundle](air-gapped-clouds.md#prepare-the-low-to-high-transfer-bundle).

### High-Side Upload Without a Customer Download Manifest

On high, place selected complete artifact ZIPs and manual built-in prerequisites at the
`customer/artifacts/` root. A complete unpackaged artifact goes under
`customer/artifacts/<ArtifactName>/` instead. Do not stage both forms of the same artifact.
After connecting to the target cloud, run from the repository root:

```powershell
.\deployments\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId '<artifactsStorageAccountResourceId>' `
    -CustomerDownloadsMode None
```

The script packages customer folders, passes root files through unchanged, and obtains base
Microsoft files from the cloud-selected sources. No customer `downloads.json` is required.
If those endpoints are unreachable, first obtain and stage every required target-cloud file from
approved internal distribution, then add `-SkipDownloadingNewSources`. That flag skips all source
downloads and does not validate workload completeness.

### Standard Update (by Resource ID)

Download latest sources and upload — resource ID from deployment output:

```powershell
Connect-AzAccount -Environment AzureUSGovernment
Set-AzContext -Subscription "<subscription-id>"
cd C:\repos\FederalAVD\deployments

.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avd-image-management-usgv/providers/Microsoft.Storage/storageAccounts/saimgassetsusgvabc123"
```

### Standard Update (by Name + Resource Group)

Useful when you know the storage account name but don't have the full resource ID handy:

```powershell
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsusgvabc123" `
    -ResourceGroupName "rg-avd-image-management-usgv"
```

### Re-Package and Re-Upload Without Downloading

Skip the download phase and re-package the existing staged artifacts directory contents (useful when artifacts are already current or download endpoints are unreachable):

```powershell
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsusgvabc123" `
    -ResourceGroupName "rg-avd-image-management-usgv" `
    -SkipDownloadingNewSources
```

### Clean Upload

Delete all existing blobs first, then upload fresh:

```powershell
.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "/subscriptions/.../storageAccounts/saimgassetsusgvabc123" `
    -DeleteExistingBlobs
```

### Include Optional Software

Merge additional downloads (e.g., PowerShell 7, VS Code, LGPO) on top of the auto-detected base file by placing `downloads.json` under `customer/parameters/imageManagement/`:

```powershell
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsusgvabc123" `
    -ResourceGroupName "rg-avd-image-management-usgv"
```

If `customer/parameters/imageManagement/downloads.json` exists, the script merges it automatically.

## Environment Detection

The script automatically selects the base downloads file from `deployments/shared/data/` based on the connected Azure environment:

| Azure Environment | Base File |
| --- | --- |
| AzureCloud | `deployments/shared/data/public.downloads.parameters.json` |
| AzureUSGovernment | `deployments/shared/data/public.downloads.parameters.json` |
| Azure Secret (IL6) | `deployments/shared/data/secret.downloads.parameters.json` |
| Azure Top Secret (IL7) | `deployments/shared/data/topsecret.downloads.parameters.json` |

The base files contain the software entries that are required by the image build template (FSLogix, M365, OneDrive, Teams, WebView2, etc.). To include optional or customer-specific software on top, create `customer/parameters/imageManagement/downloads.json`.

## Software Download Configuration

Customer-specific download definitions live at `customer/parameters/imageManagement/downloads.json` and are automatically merged on top of the environment-selected base file at runtime.

Each top-level key is a unique entry name. The following fields are shared across all methods:

| Field | Required | Description |
| --- | --- | --- |
| `Description` | No | Human-readable description of what is being downloaded |
| `DestinationFileName` | Yes | File name to save the downloaded file as |
| `DestinationFolders` | No | Array of artifact folder names to copy the downloaded file into. Defaults to the blob container root when omitted. Use `""` explicitly to place the file in the root alongside zipped packages. |

### Supported Download Methods

#### 1. Direct URL

Downloads a file from a static URL.

```json
"GoogleChromeEnterprise": {
    "Description": "Google Chrome Enterprise Installer",
    "DownloadUrl": "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",
    "DestinationFileName": "GoogleChromeEnterprise.msi",
    "DestinationFolders": [ "Google-Chrome-Enterprise" ]
}
```

| Field | Description |
| --- | --- |
| `DownloadUrl` | Direct download URL |

#### 2. Web Scraping

Searches a web page for a download link that matches a string pattern.

```json
"Microsoft365Apps": {
    "Description": "Microsoft 365 Apps Deployment Tool",
    "WebSiteUrl": "https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117",
    "SearchString": "officedeploymenttool_",
    "DestinationFileName": "officedeploymenttool.exe",
    "DestinationFolders": [ "Microsoft365Apps" ]
}
```

| Field | Description |
| --- | --- |
| `WebSiteUrl` | Page URL to scrape for a download link |
| `SearchString` | Substring used to identify the correct link on that page |

#### 3. API

Retrieves the latest version from a JSON API endpoint.

```json
"EdgeEnterpriseAdministrativeTemplates": {
    "Description": "Microsoft Edge Enterprise Administrative Templates",
    "APIUrl": "https://edgeupdates.microsoft.com/api/products?view=enterprise",
    "DestinationFileName": "EdgeEnterprisePolicyTemplates.cab",
    "DestinationFolders": [ "Configure-EdgePolicy" ]
}
```

| Field | Description |
| --- | --- |
| `APIUrl` | JSON API endpoint that returns version/download metadata |

#### 4. GitHub Releases

Fetches one or more assets from the latest release of a GitHub repository.

```json
"PowerShell7": {
    "Description": "PowerShell 7",
    "GitHubRepo": "PowerShell/PowerShell",
    "GitHubFileNamePattern": "*win-x64.msi",
    "DestinationFileName": "PowerShell7.msi",
    "DestinationFolders": [ "Microsoft-PowerShell-7" ]
}
```

| Field | Description |
| --- | --- |
| `GitHubRepo` | `owner/repo` path on GitHub |
| `GitHubFileNamePattern` | Wildcard pattern that must match exactly one release asset |
| `GitHubFileNamePatterns` | Array of wildcard patterns for a grouped download; every pattern must match exactly one asset from the same release |
| `DestinationCleanupPatterns` | Optional wildcard patterns for stale payload files to remove from each destination before copying grouped assets; authored files are preserved |

Use either `GitHubFileNamePattern` with `DestinationFileName` for one asset, or
`GitHubFileNamePatterns` for a group whose original release filenames must be preserved. A grouped
download writes directly to its first artifact destination and verifies any SHA256 digest published
by GitHub. Additional destinations receive the verified files from that first destination.

Release metadata is cached by repository for the duration of the update. Each pattern must match
exactly one asset; zero or multiple matches stop that download rather than selecting an arbitrary
file.

#### 5. Winget

Downloads the installer for a Winget package by its package identifier or product code.

```json
"AdobeAcrobatReaderDC": {
    "Description": "Adobe Acrobat Reader DC",
    "WingetId": "XPDP273C0XHQH2",
    "DestinationFileName": "AcrobatRdrDCx64.exe",
    "DestinationFolders": [ "Adobe-Acrobat-Reader-DC" ]
}
```

| Field | Description |
| --- | --- |
| `WingetId` | Winget package identifier or Microsoft Store product code |

#### Automatic Store fallback after WinGet failure

Store-packaged apps continue to use the **same product ID in `WingetId`**. No second ID, URL,
or opt-in flag is required. For example, add this entry to your customer-owned downloads file
only if your organization is licensed to deploy this HEVC extension:

```json
"HEVCVideoExtension": {
    "Description": "HEVC Video Extension - deployment requires appropriate licensing",
    "WingetId": "9N4WGH0Z6VHQ",
    "WingetPreserveLayout": true,
    "DestinationFolders": [ "BuiltIn-UWP-Apps\\HEVCVideoExtension" ]
}
```

The sequence is:

1. Try `winget download` as before.
2. If WinGet fails, is unavailable after App Installer registration, or returns success without a
   main APPX/MSIX file, log the failure and try Microsoft's Store catalog/delivery services.
3. Select the newest x64/neutral main package and the newest dependencies per package family,
   resource ID, and x86/x64/neutral architecture. Preserve x86 dependencies for bundle provisioning.
   An encrypted-only newest version causes an error, not an implicit downgrade.
4. Verify each file's byte count and Microsoft-published SHA256 digest (SHA1 is accepted only for
   HTTPS package URLs when no SHA256 digest is available). Microsoft's metadata is fetched over
   HTTPS, but its CDN sometimes supplies HTTP package URLs. Those URLs are used with an explicit
   warning and **mandatory SHA256 verification**; without SHA256 the download fails. HTTPS
   certificate checks are never disabled, and HTTPS URLs are never downgraded. Name files using
   their package identities and place dependencies under `Dependencies\<architecture>`.
5. Reuse the existing staging, main-variant pruning, shared-dependency deduplication, packaging,
   and optional `-CopyDownloadsToCustomerArtifacts` flow. `uploadedFileVersionInfo.txt` records
   whether WinGet or the direct Store fallback supplied each download.

Fallback eligibility requires all of the following:

- A 12-character Store product ID in `WingetId`.
- `WingetPreserveLayout: true`.
- `WingetSource: "msstore"`, or no source override (preserve-layout entries default to `msstore`).
- `Architecture: "x64"` (the default) or `"neutral"`; neutral still targets x64 AVD host staging.
- A public/connected downloads manifest, including local `-PackageOnly` staging.

Community-source entries (`WingetSource: "winget"`), dotted package IDs, single-file downloads,
other architecture overrides, and Secret/Top Secret manifests never invoke this fallback.
Successful WinGet downloads are unchanged. Both methods failing stops the update instead of
packaging a partial fallback download.

The fallback uses an **undocumented, experimental Microsoft interface** and cannot obtain licenses,
decrypt packages, or grant access to restricted Store content. Metadata selection is not a Windows
applicability/installation test: validate the selected version and dependencies on the target image
before production deployment. No offline license file is generated. Continue to use
`-SkipDownloadingNewSources` with approved, pre-staged files inside air-gapped environments.

#### Integrated Microsoft Store resolver

The `Get-MicrosoftStorePackageUrl` helper function is included directly in
[`Update-ImageArtifacts.ps1`](../deployments/Update-ImageArtifacts.ps1). The fallback calls it
automatically; no separate resolver script, relative tools-folder dependency, third-party
library, rg-adguard service, or account token is required.

Continue to supply the product ID through `WingetId` in your downloads manifest. The internal
resolver returns package identities, main-package classification, sizes, digests, encryption
indicators, and temporary Microsoft-hosted URLs for the staging helper to select and verify.

This is an **experimental, undocumented interface**, not a supported Microsoft download API or a
separate manifest download method. `Update-ImageArtifacts.ps1` uses it only as the WinGet fallback
described above. It enumerates package metadata using a synthetic
Windows 11 desktop profile, not the local machine's applicability rules. Results can include older
versions and dependencies; do not install every result or interpret an architecture filter as
proof that a neutral bundle supports that architecture. Microsoft controls flight availability.
Products without a delivery category, entitlement-restricted packages, and non-packaged desktop
installers may not be resolvable. Service errors stop the script rather than silently omitting files.

Links expire and must not be treated as permanent `DownloadUrl` manifest entries. Download selected
unencrypted packages promptly on a connected staging machine, verify their digests and signatures,
and retain all required dependencies. `IsEncrypted: True` denotes encrypted package files; this tool
does not decrypt them or obtain offline licenses. A download URL does not grant installation or
redistribution rights. Prefer the existing WinGet workflow for supported package downloads.

For air-gapped builds, transfer approved, verified files through the authorized process and place
them in the appropriate `customer/artifacts/` package before packaging with
`-SkipDownloadingNewSources`. Do not run this public Store lookup inside the enclave. See the
[Air-Gapped Cloud Guide](air-gapped-clouds.md).

Protocol reference: [StoreLib's public interface description](https://github.com/StoreDev/StoreLib).
For the supported download command, see [Microsoft's WinGet documentation](https://learn.microsoft.com/en-us/windows/package-manager/winget/download).

#### Finding a WingetId

Two ID formats are used depending on the software source:

**Standard package IDs** — dotted `Publisher.Package` format for most packages. Find them with:

```powershell
winget search "<name>"
```

Example output:

```text
PS> winget search "git for windows"
Name  Id       Version  Source
-------------------------------
Git   Git.Git  2.47.1   winget
```

Use the value in the `Id` column as `WingetId`.

**Microsoft Store product codes** — alphanumeric codes (e.g., `XPDP273C0XHQH2`) for Store-sourced apps. Find them with:

```powershell
winget search "<name>" --source msstore
```

Use `winget show <id>` to confirm the package details before adding to your config.

> **Air-gapped environments:** `WingetId` entries require outbound internet access to winget's CDN or the Microsoft Store. They are not usable in air-gapped clouds. See [Air-Gapped Cloud Guide](air-gapped-clouds.md) for alternatives.

#### 6. Winget - Preserve Layout (UWP / MSIX packages)

Use `WingetPreserveLayout: true` when downloading Store-distributed MSIX or MSIXBUNDLE packages
that must keep their original filenames and folder structure. This mode is used for built-in UWP
apps (Calculator, Paint, Snipping Tool, etc.) and codec extensions.

```json
"WindowsCalculator": {
    "Description": "Windows Calculator - built-in UWP app provisioned for all users",
    "WingetId": "9WZDNCRFHVN5",
    "WingetPreserveLayout": true,
    "DestinationFolders": [ "BuiltIn-UWP-Apps\\Calculator" ]
},
"MicrosoftClipchamp": {
    "Description": "Clipchamp - built-in UWP video editor provisioned for all users",
    "WingetId": "9P1J8S7CCWWT",
    "WingetPreserveLayout": true,
    "Architecture": "neutral",
    "DestinationFolders": [ "BuiltIn-UWP-Apps\\Clipchamp" ]
}
```

| Field | Description |
| --- | --- |
| `WingetId` | Microsoft Store product code (alphanumeric) |
| `WingetPreserveLayout` | `true` -- preserves the `winget download` folder layout; no `DestinationFileName` used |
| `WingetSource` | Optional source override: `msstore` or `winget`. Preserve-layout entries default to `msstore`. |
| `Architecture` | Optional. Omit for most apps (`x64` is the default). Set to `"neutral"` for multi-arch bundles that do not publish a separate x64 installer (e.g., Clipchamp). |
| `DestinationFolders` | Single entry naming the app subfolder inside the parent artifact folder (e.g., `BuiltIn-UWP-Apps\\Calculator`) |

**How it works:**

1. `winget download --id <WingetId> --download-directory <temp>` is called (with `--architecture x64` unless `Architecture` is `"neutral"`).
2. The destination folder is cleaned before copying to prevent stale package accumulation.
3. Dependency zip archives from community winget manifests are expanded before package processing.
4. Only `x64` and `neutral` architecture files are copied from any `Dependencies\` subfolder; other arch variants are pruned.
5. After all preserve-layout downloads complete, shared framework packages (VCLibs, WinAppSDK, UI.Xaml, etc.) are deduplicated across all app subfolders into a single `SharedDependencies\` folder at the parent artifact root, reducing the zip size.

> **Note:** `WingetPreserveLayout` entries do not use `DestinationFileName`. The original filenames produced by `winget download` are kept so that `Add-AppxProvisionedPackage` can read the package metadata correctly.

See [BuiltIn-UWP-Apps](../customer-examples/artifacts/BuiltIn-UWP-Apps/README.md) for the
full list of supported apps and setup instructions.

### Placing a File Into Multiple Artifact Folders

Set `DestinationFolders` to an array with multiple names to copy the same downloaded file into several artifact folders. This is common for tools like LGPO that are needed by multiple artifact packages:

```json
"LGPO": {
    "Description": "LGPO Tool",
    "DownloadUrl": "https://download.microsoft.com/download/8/5/c/85c25433-a1b0-4ffa-9429-7e023e7da8d8/LGPO.zip",
    "DestinationFileName": "lgpo.zip",
    "DestinationFolders": [
        "Configure-DesktopBackground",
        "Configure-EdgePolicy",
        "Configure-Office365Policy",
        "LGPO"
    ]
}
```

Use `""` (empty string) as one of the folder names to also place the file directly in the blob container root alongside the zipped packages.

## Artifacts Directory Structure

> **Getting started quickly:** `customer-examples/artifacts/` contains ready-to-use packages for common software (Chrome, FSLogix, LGPO, VS Code, STIGs, and more). Copy any folder directly into `customer/artifacts/` and run the script. See [`customer/README.md`](../customer/README.md) for the full list and copy commands.

The script stages a merged view — `deployments/shared/artifacts/` first, then `customer/artifacts/` on top — then packages the result. Currently `deployments/shared/artifacts/` is empty, so all content comes from `customer/artifacts/`.

> **Where to place pre-staged files:**
> - **Required air-gapped artifacts** (WebView2, VC Redist, WebRTC): place the file directly in `customer/artifacts/` using the exact filename specified in the downloads file (e.g., `WebView2.exe`). The script picks them up by filename from the root of the artifacts directory.
> - **Custom application packages**: place the installer and any scripts in a named subdirectory, e.g., `customer/artifacts/Google-Chrome-Enterprise/`. The subdirectory name becomes the zip/package name.
> - **Prebuilt artifact ZIPs transferred from low**: place only selected approved ZIPs at the root of `customer/artifacts/`; they are uploaded unchanged. Do not copy the full local-package output, and do not also stage the same artifact's source folder.
> - If you use `-CustomerRootPath`, substitute `<CustomerRootPath>\artifacts\` for `customer/artifacts/` in both cases above.

```text
stagedArtifacts/
├── uploadedFileVersionInfo.txt        (auto-generated version log)
├── Google-Chrome-Enterprise/          → compressed to Google-Chrome-Enterprise.zip
│   ├── Install-Chrome.ps1
│   └── GoogleChromeEnterprise.msi
├── LGPO/                              → compressed to LGPO.zip
│   ├── Install-LGPO.ps1
│   └── LGPO.exe
└── teamsbootstrapper.exe              → uploaded as-is (root file)
```

If `deployments/shared/artifacts/` contains packages in the future, `customer/artifacts/` overlays on top — customer files always win when names match.

Each subdirectory is compressed into a zip file and uploaded to the `artifacts` blob container.

**For full details on creating custom artifact packages:** [Artifacts and Image Management Guide](artifacts-guide.md)

## Output

On successful completion, the script prints the artifacts container URL:

```text
Artifacts container URL: 'https://saimgassetsusgvabc123.blob.core.usgovcloudapi.net/artifacts/'
```

Pass this URL as `artifactsContainerUri` in image build deployments.

## Troubleshooting

**Storage access denied (403)**
- Verify **Storage Blob Data Contributor** is assigned to your Entra identity on the storage account (not just at subscription/RG level)
- Confirm the storage account has not disabled public network access without a private endpoint or service endpoint configured for your client

**Download failures**
- Check internet connectivity from the machine running the script
- Verify URLs in the downloads parameter file are still valid
- On high, use `-CustomerDownloadsMode None` to keep public customer entries out of the download phase. If base endpoints are unreachable, obtain the required target-cloud files through approved internal distribution before using `-SkipDownloadingNewSources`. Do not replace them with public low-side outputs. See the [Air-Gapped Cloud Guide](air-gapped-clouds.md).

**Parameter file not found**
- The base downloads files are in `deployments/shared/data/` and are included with the repository — they should always be present
- If you expect optional downloads to be merged, verify `customer/parameters/imageManagement/downloads.json` exists and contains valid JSON

## Related Resources

- [Quick Start Guide](quick-start.md) — End-to-end deployment walkthrough
- [imageManagement README](../deployments/imageManagement/README.md) — Infrastructure deployment reference
- [Artifacts Guide](artifacts-guide.md) — Creating and managing custom artifact packages
- [Air-Gapped Cloud Guide](air-gapped-clouds.md) — Secret/Top Secret cloud considerations
- [Troubleshooting](troubleshooting.md) — Common issues and solutions

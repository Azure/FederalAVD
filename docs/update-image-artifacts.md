[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

> **📚 Conceptual Guide:** For how the artifact system works, how artifacts are executed during image builds and session host deployments, and how to create custom artifact packages, see the [Artifacts and Image Management Guide](artifacts-guide.md).

# Update-ImageArtifacts.ps1 Script Guide

## Overview

`Update-ImageArtifacts.ps1` is a PowerShell script that downloads the latest software sources, stages artifacts from `customer/artifacts/` (overlaid on any repo-provided artifacts in `.common/artifacts/`), packages them as zip files, and uploads them to the image management artifacts storage account. Run it whenever you want to refresh what is available to image build deployments — for example, after adding a new software package or after a new version is released.

> **Infrastructure vs. Artifacts:** This script does **not** deploy any Azure resources. Deploy the imageManagement template first (see [imageManagement README](../deployments/imageManagement/README.md) or [Quick Start Step 2](quick-start.md#step-2-deploy-image-management-resources)), then use this script to populate the storage account. Alternatively, use `Deploy-ImageManagement.ps1 -UpdateArtifacts` to do both in one step.

## Notes

- In air-gapped clouds (Secret/Top Secret), the script auto-detects the environment and downloads from air-gapped cloud endpoints — no special switch is required. For artifacts with no configured download URL (FSLogix, WebView2, etc.), manually place the files in the `artifacts/` subdirectory of your customer root (default: `customer/artifacts/`; or `<CustomerRootPath>\artifacts\` when `-CustomerRootPath` is specified) before running. See the [Air-Gapped Cloud Guide](air-gapped-clouds.md) for details.
- Use `-DeleteExistingBlobs` for a clean upload when removing old packages.
- Use `-CustomerRootPath <path>` to point to a folder outside the repo zip (e.g., a persistent share or pipeline workspace). Pre-staged artifact files go in `<CustomerRootPath>\artifacts\`; the downloads parameter file goes in `<CustomerRootPath>\parameters\imageManagement\`.
- Use `-CustomerArtifactsMode None` or `-CustomerDownloadsMode None` to skip customer overlays when you only want repo content.
- To merge customer-owned optional downloads, place `downloads.json` in `<CustomerRootPath>\parameters\imageManagement\`; the script discovers it automatically.

## What This Script Does

Three sequential phases:

1. **Download** — Fetches the latest versions of software from the internet using the downloads parameter file (skipped with `-SkipDownloadingNewSources` or when no downloads file exists)
2. **Package** — Compresses each subdirectory in the staged artifacts view (repo base in `.common/artifacts/` overlaid by `customer/artifacts/`)
3. **Upload** — Uploads all packaged artifacts to the `artifacts` blob container in the storage account

## Prerequisites

### Required Permissions

- **Storage Blob Data Contributor** on the image management artifacts storage account — required because the storage account disables shared key access (Zero Trust). `Contributor` or `Owner` on the subscription or resource group does **not** grant blob data access. See [full explanation](hostpool-deployment.md#security-prerequisites-optional).

### Required Tools

- PowerShell 5.1 or PowerShell 7+
- Azure PowerShell Az module
- Active Azure login (`Connect-AzAccount`)

### Required Files

Base downloads parameter files are in `.common/data/` and are selected automatically based on the connected Azure environment — no action needed:

  - `.common/data/public.downloads.parameters.json` (commercial / government)
  - `.common/data/secret.downloads.parameters.json` (Azure Secret)
  - `.common/data/topsecret.downloads.parameters.json` (Azure Top Secret)

To download **optional** software (e.g., PowerShell 7, VS Code, LGPO, Git), place a customer-owned downloads file at `customer/parameters/imageManagement/downloads.json`. A ready-to-use example that covers a broad set of common packages is provided at:
  - `customer/examples/parameters/imageManagement/downloads.json`

Copy it to the auto-discovered location:

```powershell
Copy-Item -Path "customer\examples\parameters\imageManagement\downloads.json" `
          -Destination "customer\parameters\imageManagement\" -Force
```

A minimal reference file with only the repo-required entries is also available at:
  - `deployments/imageManagement/parameters/sample-optional.downloads.parameters.json`

## Parameters

The storage account can be identified by **either** its full resource ID **or** its name and resource group — these are mutually exclusive parameter sets.

### Parameter Set 1: By Resource ID (default)

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| **StorageAccountResourceId** | String | **Yes** | Full resource ID of the artifacts storage account. Obtain from the `artifactsStorageAccountResourceId` imageManagement deployment output. |

### Parameter Set 2: By Name

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| **StorageAccountName** | String | **Yes** | Name of the artifacts storage account. |
| **ResourceGroupName** | String | **Yes** | Resource group containing the storage account. |

### Common Parameters (both sets)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| **DeleteExistingBlobs** | Switch | `$false` | Delete all existing blobs in the container before uploading. Use for a clean refresh rather than incremental update. |
| **SkipDownloadingNewSources** | Switch | `$false` | Skip downloading new software. Use in air-gapped environments or when the artifacts directory is already current. |
| **TempDir** | String | `$Env:Temp` | Temporary directory for packaging. Use a path on a high-performance drive for large artifact sets. |

## Usage Examples

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

The script automatically selects the base downloads file from `.common/data/` based on the connected Azure environment:

| Azure Environment | Base File |
|-------------------|-----------|
| AzureCloud | `.common/data/public.downloads.parameters.json` |
| AzureUSGovernment | `.common/data/public.downloads.parameters.json` |
| Azure Secret (IL6) | `.common/data/secret.downloads.parameters.json` |
| Azure Top Secret (IL7) | `.common/data/topsecret.downloads.parameters.json` |

The base files contain the software entries that are required by the image build template (FSLogix, M365, OneDrive, Teams, WebView2, etc.). To include optional or customer-specific software on top, create `customer/parameters/imageManagement/downloads.json`.

## Software Download Configuration

Customer-specific download definitions live at `customer/parameters/imageManagement/downloads.json` and are automatically merged on top of the environment-selected base file at runtime.

Each top-level key is a unique entry name. The following fields are shared across all methods:

| Field | Required | Description |
|-------|----------|-------------|
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
|-------|-------------|
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
|-------|-------------|
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
|-------|-------------|
| `APIUrl` | JSON API endpoint that returns version/download metadata |

#### 4. GitHub Releases

Fetches the latest release asset from a GitHub repository.

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
|-------|-------------|
| `GitHubRepo` | `owner/repo` path on GitHub |
| `GitHubFileNamePattern` | Wildcard pattern to match the desired release asset filename |

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
|-------|-------------|
| `WingetId` | Winget package identifier or Microsoft Store product code |

#### Finding a WingetId

Two ID formats are used depending on the software source:

**Standard package IDs** — dotted `Publisher.Package` format for most packages. Find them with:

```powershell
winget search "<name>"
```

Example output:

```
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
|-------|-------------|
| `WingetId` | Microsoft Store product code (alphanumeric) |
| `WingetPreserveLayout` | `true` -- preserves the `winget download` folder layout; no `DestinationFileName` used |
| `Architecture` | Optional. Omit for most apps (`x64` is the default). Set to `"neutral"` for multi-arch bundles that do not publish a separate x64 installer (e.g., Clipchamp). |
| `DestinationFolders` | Single entry naming the app subfolder inside the parent artifact folder (e.g., `BuiltIn-UWP-Apps\\Calculator`) |

**How it works:**

1. `winget download --id <WingetId> --download-directory <temp>` is called (with `--architecture x64` unless `Architecture` is `"neutral"`).
2. The destination folder is cleaned before copying to prevent stale package accumulation.
3. Only `x64` and `neutral` architecture files are copied from any `Dependencies\` subfolder; other arch variants are pruned.
4. After all preserve-layout downloads complete, shared framework packages (VCLibs, WinAppSDK, UI.Xaml, etc.) are deduplicated across all app subfolders into a single `SharedDependencies\` folder at the parent artifact root, reducing the zip size.

> **Note:** `WingetPreserveLayout` entries do not use `DestinationFileName`. The original filenames produced by `winget download` are kept so that `Add-AppxProvisionedPackage` can read the package metadata correctly.

See [BuiltIn-UWP-Apps](../customer/examples/artifacts/BuiltIn-UWP-Apps/README.md) for the
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

> **Getting started quickly:** `customer/examples/artifacts/` contains ready-to-use packages for common software (Chrome, FSLogix, LGPO, VS Code, STIGs, and more). Copy any folder directly into `customer/artifacts/` and run the script. See [`customer/README.md`](../customer/README.md) for the full list and copy commands.

The script stages a merged view — `.common/artifacts/` first, then `customer/artifacts/` on top — then packages the result. Currently `.common/artifacts/` is empty, so all content comes from `customer/artifacts/`.

> **Where to place pre-staged files:**
> - **Required air-gapped artifacts** (FSLogix, WebView2, VC Redist, WebRTC): place the file directly in `customer/artifacts/` using the exact filename specified in the downloads file (e.g., `FSLogix.zip`, `WebView2.exe`). The script picks them up by filename from the root of the artifacts directory.
> - **Custom application packages**: place the installer and any scripts in a named subdirectory, e.g., `customer/artifacts/Google-Chrome-Enterprise/`. The subdirectory name becomes the zip/package name.
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

If `.common/artifacts/` contains packages in the future, `customer/artifacts/` overlays on top — customer files always win when names match.

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
- Use `-SkipDownloadingNewSources` when download endpoints are unreachable and you want to re-package and re-upload already-staged content. For normal air-gapped cloud deployments, the script downloads automatically — see the [Air-Gapped Cloud Guide](air-gapped-clouds.md).

**Parameter file not found**
- The base downloads files are in `.common/data/` and are included with the repository — they should always be present
- If you expect optional downloads to be merged, verify `customer/parameters/imageManagement/downloads.json` exists and contains valid JSON

## Related Resources

- [Quick Start Guide](quick-start.md) — End-to-end deployment walkthrough
- [imageManagement README](../deployments/imageManagement/README.md) — Infrastructure deployment reference
- [Artifacts Guide](artifacts-guide.md) — Creating and managing custom artifact packages
- [Air-Gapped Cloud Guide](air-gapped-clouds.md) — Secret/Top Secret cloud considerations
- [Troubleshooting](troubleshooting.md) — Common issues and solutions

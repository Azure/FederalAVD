↩ **Back to:** [Quick Start](quickStart.md)

[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**BCDR**](bcdr.md)

# Update-ImageArtifacts.ps1 Script Guide

## Overview

`Update-ImageArtifacts.ps1` is a PowerShell script that downloads the latest software sources, packages them as zip files, and uploads them to the image management artifacts storage account. Run it whenever you want to refresh what is available to image build deployments — for example, after adding a new software package or after a new version is released.

> **Infrastructure vs. Artifacts:** This script does **not** deploy any Azure resources. Deploy the imageManagement template first (see [imageManagement README](../deployments/imageManagement/README.md) or [Quick Start Step 2](quickStart.md#step-2-deploy-image-management-resources)), then use this script to populate the storage account. Alternatively, use `Deploy-ImageManagement.ps1 -UpdateArtifacts` to do both in one step.

## What This Script Does

Three sequential phases:

1. **Download** — Fetches the latest versions of software from the internet using the downloads parameter file (skipped with `-SkipDownloadingNewSources` or when no downloads file exists)
2. **Package** — Compresses each subdirectory in `.common/artifacts/` into a zip file
3. **Upload** — Uploads all packaged artifacts to the `artifacts` blob container in the storage account

## Prerequisites

### Required Permissions

- **Storage Blob Data Contributor** on the image management artifacts storage account — required because the storage account disables shared key access (Zero Trust). `Contributor` or `Owner` on the subscription or resource group does **not** grant blob data access. See [full explanation](hostpoolDeployment.md#security-prerequisites-optional).

### Required Tools

- PowerShell 5.1 or PowerShell 7+
- Azure PowerShell Az module
- Active Azure login (`Connect-AzAccount`)

### Required Files

Base downloads parameter files are in `.common/data/` and are selected automatically based on the connected Azure environment — no action needed:
  - `.common/data/public.downloads.parameters.json` (commercial / government)
  - `.common/data/secret.downloads.parameters.json` (IL6)
  - `.common/data/topsecret.downloads.parameters.json` (IL7)

To download **optional** software (e.g., PowerShell 7, VS Code, LGPO, Git), supply an additional JSON file via `-AdditionalDownloadsFilePath`. A ready-to-use example for public cloud environments is provided at:
  - `deployments/imageManagement/parameters/public.downloads.optional.parameters.json`

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
| **AdditionalDownloadsFilePath** | String | *(none)* | Full path to an additional downloads JSON file to merge with the base environment file. Entries in this file are merged on top — existing keys are overwritten, new keys are added. |
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

### Air-Gapped / Offline Update

Skip internet downloads — re-package and upload the existing artifacts directory contents:

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

Merge additional downloads (e.g., PowerShell 7, VS Code, LGPO) on top of the auto-detected base file:

```powershell
.\Update-ImageArtifacts.ps1 `
    -StorageAccountName "saimgassetsusgvabc123" `
    -ResourceGroupName "rg-avd-image-management-usgv" `
    -AdditionalDownloadsFilePath "C:\repos\FederalAVD\deployments\imageManagement\parameters\public.downloads.optional.parameters.json"
```

You can supply any JSON file in the same format — only entries present in the file are merged.

## Environment Detection

The script automatically selects the base downloads file from `.common/data/` based on the connected Azure environment:

| Azure Environment | Base File |
|-------------------|-----------|
| AzureCloud | `.common/data/public.downloads.parameters.json` |
| AzureUSGovernment | `.common/data/public.downloads.parameters.json` |
| Azure Secret (IL6) | `.common/data/secret.downloads.parameters.json` |
| Azure Top Secret (IL7) | `.common/data/topsecret.downloads.parameters.json` |

The base files contain the software entries that are required by the image build template (FSLogix, M365, OneDrive, Teams, WebView2, etc.). Use `-AdditionalDownloadsFilePath` to include optional software on top.

## Software Download Configuration

Downloads are defined in JSON files under `deployments/imageManagement/parameters/`:

```json
{
  "Microsoft365Apps": {
    "WebSiteUrl": "https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117",
    "SearchString": "officedeploymenttool_",
    "DestinationFileName": "officedeploymenttool.exe",
    "DestinationFolders": ["Microsoft365Apps"]
  },
  "MicrosoftEdge": {
    "APIUrl": "https://edgeupdates.microsoft.com/api/products",
    "DestinationFileName": "MicrosoftEdgePolicyTemplates.cab",
    "DestinationFolders": ["MicrosoftEdgePolicyTemplates"]
  }
}
```

### Supported Download Methods

1. **Direct URL** — Static download URL
2. **Web Scraping** — Searches a web page for a download link using a search string
3. **API** — Retrieves latest version from an API endpoint (e.g., Microsoft Edge)
4. **GitHub Releases** — Fetches the latest release asset from a GitHub repository
5. **Winget** — Downloads via the Windows Package Manager
6. **Evergreen** — Uses the Evergreen PowerShell module for dynamic version resolution

## Artifacts Directory Structure

The script packages the `.common/artifacts/` directory:

```text
.common/artifacts/
├── uploadedFileVersionInfo.txt  (auto-generated version log)
├── FSLogix/
│   ├── Install_FSLogix.ps1
│   └── FSLogixAppsSetup.exe
├── Microsoft365Apps/
│   ├── Install_M365Apps.ps1
│   └── officedeploymenttool.exe
└── CustomScript/
    ├── Install_CustomScript.ps1
    └── installer.msi
```

Each subdirectory is compressed into a zip file and uploaded to the `artifacts` blob container.

**For full details on creating custom artifact packages:** [Artifacts and Image Management Guide](artifactsGuide.md)

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
- Use `-SkipDownloadingNewSources` and manually place files in `.common/artifacts/` for air-gapped scenarios

**Parameter file not found**
- The base downloads files are in `.common/data/` and are included with the repository — they should always be present
- Verify the `-AdditionalDownloadsFilePath` value (if provided) points to an existing file with a valid full path

## Related Resources

- [Quick Start Guide](quickStart.md) — End-to-end deployment walkthrough
- [imageManagement README](../deployments/imageManagement/README.md) — Infrastructure deployment reference
- [Artifacts Guide](artifactsGuide.md) — Creating and managing custom artifact packages
- [Air-Gapped Cloud Guide](airGappedClouds.md) — Secret/Top Secret cloud considerations
- [Troubleshooting](troubleshooting.md) — Common issues and solutions


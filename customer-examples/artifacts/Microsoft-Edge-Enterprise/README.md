# Microsoft-Edge-Enterprise

> **Before you start:** Copy this folder to `customer/artifacts/Microsoft-Edge-Enterprise/` before running `Update-ImageArtifacts.ps1`. Add the `MicrosoftEdgeEnterprise` entry from [`customer-examples/parameters/imageManagement/downloads.json`](../../../customer-examples/parameters/imageManagement/downloads.json) to your `customer/parameters/imageManagement/downloads.json`. See the [example artifacts README](../README.md) for the full workflow.

Installs the latest **Microsoft Edge Enterprise Stable x64** MSI silently and, optionally,
disables Edge's auto-update mechanism via Group Policy registry keys.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DisableUpdates` | `bool` | `$true` | Write `UpdateDefault = 0` to the EdgeUpdate policy keys after install. Recommended for VDI/AVD where the golden image owns the browser version. |

## Folder contents

```plaintext
Microsoft-Edge-Enterprise/
    Install-MicrosoftEdgeEnterprise.ps1   <- installer script (required)
    MicrosoftEdgeEnterpriseX64.msi        <- pre-staged MSI (optional; required for air-gapped)
```

The MSI file is optional for **connected** image builds — the script fetches it automatically
from Microsoft's Edge Updates API if no `.msi` is found in the folder. For **air-gapped** builds
the MSI must be pre-staged (see below).

## How to get the installer

### Option 1 — Update-ImageArtifacts.ps1 (recommended for connected environments)

Add the following entry to `customer/parameters/imageManagement/downloads.json`:

```json
"MicrosoftEdgeEnterprise": {
    "Description": "Microsoft Edge Enterprise Stable x64 MSI. The install script also downloads this at image build time if not pre-staged.",
    "APIUrl": "https://edgeupdates.microsoft.com/api/products?view=enterprise",
    "APIArtifact": "msi",
    "DestinationFileName": "MicrosoftEdgeEnterpriseX64.msi",
    "DestinationFolders": ["Microsoft-Edge-Enterprise"]
}
```

Then run:

```powershell
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

`Update-ImageArtifacts.ps1` calls the Edge Updates API, resolves the latest Stable x64 MSI URL,
and uploads it to your artifacts storage account alongside the script.

### Option 2 — Manual download (connected, no automation)

1. Open the [Microsoft Edge for Business download page](https://www.microsoft.com/en-us/edge/business/download).
2. Select **Windows 64-bit**, channel **Stable**, and click **Download**.  
   — or —  
   Call the API directly in PowerShell:

   ```powershell
   $content = (Invoke-WebRequest 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -UseBasicParsing).Content | ConvertFrom-Json
   $releases = ($content | Where-Object { $_.Product -eq 'Stable' }).releases
   $latest = $releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } |
       Sort-Object ProductVersion | Select-Object -Last 1
   $url = ($latest.artifacts | Where-Object { $_.ArtifactName -eq 'msi' }).Location
   Invoke-WebRequest $url -OutFile 'MicrosoftEdgeEnterpriseX64.msi'
   ```

3. Place `MicrosoftEdgeEnterpriseX64.msi` in this folder before uploading to blob storage.

### Option 3 — Air-gapped / manual pre-staging

1. On a machine with internet access, download the MSI using the API call above (Option 2, step 2),
   or from your organization's patch management system.
2. Copy `MicrosoftEdgeEnterpriseX64.msi` into this folder alongside the install script.
3. Transfer the folder to the air-gapped network, then upload to blob storage:

   ```powershell
   .\Update-ImageArtifacts.ps1 `
       -StorageAccountResourceId "<artifactsStorageAccountResourceId>" `
       -SkipDownloadingNewSources
   ```

   When a `.msi` file is present in the folder, the install script uses it directly and skips
   the API call entirely — no internet access is required during the image build.

## What the script does

1. Searches `$PSScriptRoot` for a `.msi` file. Uses the first one found (newest if multiple).
2. If no `.msi` is found, calls the Edge Updates API and downloads the latest Stable x64 MSI
   to `$env:TEMP`.
3. Installs Edge silently: `msiexec /i "<path>.msi" /quiet /norestart`.
4. If `$DisableUpdates` is `$true` (default), sets `UpdateDefault = 0` under:
   - `HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate`
   - `HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\EdgeUpdate`

## Exit codes

| Exit Code | Meaning |
|---|---|
| `0` | Success |
| `3010` | Success — reboot required |
| Other | Installer error — review `C:\Windows\Logs\Install-MicrosoftEdgeEnterprise-*.log` |

## Refresh cadence

A new Edge Stable release ships approximately every 4 weeks. Re-run `Update-ImageArtifacts.ps1`
(or repeat the manual download) before each image build cycle to stay current.

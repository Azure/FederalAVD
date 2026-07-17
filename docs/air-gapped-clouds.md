↩ **Back to:** [Quick Start](quick-start.md)

[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Air-Gapped Cloud Considerations

The air-gapped clouds, Azure Government Secret and Azure Government Top Secret, offer unique challenges because not all software is available for download via http and where it is it may not be available to all enclaves on the networks these clouds service.

## Network Requirements & Documentation

Session hosts in air-gapped clouds require network access to specific Azure Virtual Desktop service endpoints, including AVD Agent installer download URLs and service FQDNs. Complete network requirements, required URLs, and AVD Agent installer permalinks are documented in the following cloud-specific resources:

- **[Azure Government Secret AVD Service Documentation](https://review.learn.microsoft.com/en-us/microsoft-government-secret/azure/azure-government-secret/services/virtual-desktop-infrastructure/virtual-desktop?branch=live)** - Includes required endpoints and AVD Agent installer download URLs
- **[Azure Government Top Secret AVD Service Documentation](https://review.learn.microsoft.com/en-us/microsoft-government-topsecret/azure/azure-government-top-secret/services/virtual-desktop-infrastructure/virtual-desktop?branch=live)** - Includes required endpoints and AVD Agent installer download URLs

> **📋 Access Note:** These documentation links are only accessible to Microsoft Full-Time Employees (FTEs). If you cannot access these resources, refer to the Azure Virtual Desktop documentation available on your air-gapped cloud's internal Microsoft Docs site for network requirements, required URLs, and AVD Agent installer download links specific to your environment.

## Session Host Deployment

During session host deployment (host pool creation and Session Host Replacer operations), the AVD Agent and Boot Loader must be installed on each session host.

**Download Behavior:**

**AVD Agent Boot Loader:**

- If `agentBootLoaderDownloadUrl` parameter is provided → uses the custom URL
- If `agentBootLoaderDownloadUrl` is empty (default) → uses the `https://aka.<cloudsuffix>/RdAgentBootLoader_latest` permalink (see network requirements documentation above)

**AVD Agent:**

1. Always attempts to download the latest agent version from the host pool API endpoint first
2. If endpoint fails → uses `agentDownloadUrl` (if provided) OR the `https://aka.<cloudsuffix>/RdAgent_latest` permalink

| Component | Storage Account</br>Provided | Instructions |
| :-- | :--: | :-- |
| **AVD Agent &</br>Boot Loader** | Yes | Running `Update-ImageArtifacts.ps1` automatically downloads the AVD Agent and Bootloader from the air-gapped cloud URLs and uploads them to the artifacts storage account — no manual steps required. After running the script, set `agentBootLoaderDownloadUrl` and `agentDownloadUrl` to the corresponding blob storage URLs (e.g., `https://<storageAccount>.blob.<env-suffix>/artifacts/Microsoft.RDInfra.RDAgentBootLoader.Installer-x64.msi`) to override the default permalinks.<br/><br/>If the air-gapped URLs are not reachable from the management system, download both MSI files manually, place them in `customer/artifacts/`, and run `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`.<br/><br/>**Note:** The Agent download always tries the host pool API endpoint first for the latest version, then falls back to the URL you configure. See [Parameters](parameters.md) for details. |
| **AVD Agent &</br>Boot Loader** | No | The deployment uses the default cloud-specific permalinks (see network requirements above) for both components. For the Agent, the deployment always attempts the host pool API endpoint first for the latest version before falling back to the permalink. |

📖 **Parameter Reference:** See the `agentDownloadUrl` and `agentBootLoaderDownloadUrl` parameters in [Parameters](parameters.md).

---

## Custom Image Build

### How the Downloads Configuration Works

The `Update-ImageArtifacts.ps1` script automatically selects the correct downloads configuration file from `.common/data/` based on the connected Azure environment:

| Azure Environment | Base File |
|---|---|
| AzureCloud / AzureUSGovernment | `.common/data/public.downloads.parameters.json` |
| Azure Government Secret (IL6) | `.common/data/secret.downloads.parameters.json` |
| Azure Government Top Secret (IL7) | `.common/data/topsecret.downloads.parameters.json` |

The secret and top secret files are already in the repository. Each entry either has a working air-gapped cloud URL (the script downloads it automatically) or an **empty `DownloadUrl`** (you must place the file manually before running the script).

To add software not in the base file, place `downloads.json` in `customer/parameters/imageManagement/`. The script discovers and merges it automatically. See [Update-ImageArtifacts Script Guide](update-image-artifacts.md) for the file format.

> **⚠️ WingetId entries are not supported in air-gapped environments.** Winget downloads require outbound internet access to the winget CDN or Microsoft Store, which is unavailable in air-gapped clouds. The base `secret` and `topsecret` downloads files do not use winget, so a standard run is unaffected. However, if you add a `customer/parameters/imageManagement/downloads.json` that contains `WingetId` entries, those specific entries will fail.
>
> **Alternatives for optional software in air-gapped environments:**
> - Replace `WingetId` with `DownloadUrl` pointing to an internally hosted copy (e.g., an internal web server, SharePoint site, or Azure Blob storage accessible from your management system).
> - Pre-stage the installer directly in `customer/artifacts/<FolderName>/` and omit the entry from `downloads.json` — the script will package and upload it without attempting a download.

#### Built-in UWP apps and codec extensions (air-gapped)

The `BuiltIn-UWP-Apps` artifact (Calculator, Paint, Snipping Tool, Notepad, Clipchamp, Photos,
Sticky Notes, Windows Terminal, and codec extensions) uses `WingetId` entries with
`WingetPreserveLayout: true` and therefore **cannot be downloaded automatically in air-gapped
environments**.

To use these apps in an air-gapped image build:

1. On an internet-connected system, run `Update-ImageArtifacts.ps1` once to download and stage
   the packages:

   ```powershell
   .\Update-ImageArtifacts.ps1 -StorageAccountName "<any>" -ResourceGroupName "<any>"
   ```

   The staged output is written to a local temp folder before upload. Alternatively, run with
   `-SkipDownloadingNewSources` after manually placing the winget-downloaded packages, or use
   winget directly:

   ```powershell
   winget download --id 9WZDNCRFHVN5 --download-directory "C:\stage\Calculator" --source msstore --skip-license
   # repeat for each app Store ID
   ```

2. Copy the entire staged `BuiltIn-UWP-Apps\` folder (including `SharedDependencies\`) to the
   air-gapped network and place it under `customer/artifacts/`:

   ```text
   customer\artifacts\
       BuiltIn-UWP-Apps\
           Install-BuiltinUwpApps.ps1
           Calculator\
               Microsoft.WindowsCalculator_<ver>_neutral_~_8wekyb3d8bbwe.msixbundle
           ...
           SharedDependencies\
               Microsoft.VCLibs.140.00.UWPDesktop_<ver>_x64__8wekyb3d8bbwe.appx
               ...
   ```

3. Upload to the air-gapped artifacts storage account using `-SkipDownloadingNewSources`:

   ```powershell
   .\Update-ImageArtifacts.ps1 `
       -StorageAccountResourceId "<artifactsStorageAccountResourceId>" `
       -SkipDownloadingNewSources
   ```

   The script packages the pre-staged `BuiltIn-UWP-Apps\` folder as-is and uploads it without
   attempting any winget downloads. The `Optimize-SharedDependencies` deduplication step is
   skipped when `-SkipDownloadingNewSources` is set, so ensure your staged folder already has
   the `SharedDependencies\` layout (step 1 produces this automatically).

> **Refresh cadence:** MSIX packages include the app version in the filename. Re-stage from an
> internet-connected system periodically to pick up new app versions, then repeat steps 2-3.

---

### Items That Must Be Placed Manually

The following artifacts have empty `DownloadUrl` entries in the secret and top secret downloads files — no automated download source is configured. If you wish, you can obtain these files from a reachable source (internet-connected system, Azure Toolbox, vendor portal, etc.) and place them at the paths shown before running `Update-ImageArtifacts.ps1`.

| Software | Destination Filename | Place In | Notes |
|---|---|---|---|
| **WebView2 Runtime** | `WebView2.exe` | `customer/artifacts/` | Required by Teams. Download from [go.microsoft.com/fwlink/?linkid=2124703](https://go.microsoft.com/fwlink/?linkid=2124703) on an internet-connected system. |
| **Visual Studio Redistributables** | `vc_redist.x64.exe` | `customer/artifacts/` | Required by Teams. Download from [aka.ms/vs/17/release/vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe) on an internet-connected system. |
| **Remote Desktop WebRTC Service** | `MsRdcWebRTCSvc.msi` | `customer/artifacts/` | Required for Teams media optimizations. Download from [aka.ms/msrdcwebrtcsvc/msi](https://aka.ms/msrdcwebrtcsvc/msi) on an internet-connected system. |

> **Transfer tip:** Download all of the above on an internet-connected system, copy them to the air-gapped network, then drop them into the `customer/artifacts/` directory before running the upload script.

---

### Items Downloaded Automatically from Air-Gapped Network URLs

The following artifacts have working URLs in the secret and top secret downloads files (using air-gapped cloud endpoints). `Update-ImageArtifacts.ps1` downloads them automatically when the URLs are reachable from the management system:

| Software | Destination Filename | Air-Gapped URL Pattern |
|---|---|---|
| **AVD Agent** | `Microsoft.RDInfra.RDAgent.Installer-x64.msi` | `aka.<env-suffix>/RdAgent_latest` |
| **AVD Agent Bootloader** | `Microsoft.RDInfra.RDAgentBootloader.Installer-x64.msi` | `aka.<env-suffix>/RdAgentBootLoader_latest` |
| **Office 365 Deployment Tool** | `Office365DeploymentTool.exe` | `officexo.azurefd.<env-suffix>/...` |
| **OneDrive** | `OneDriveSetup.exe` | `update.azure.odsync.<env-suffix>/...` |
| **Teams Bootstrapper** | `teamsbootstrapper.exe` | `statics.teams.<env-suffix>/...` |
| **Teams 64-bit MSIX** | `MSTeams-x64.msix` | `statics.teams.<env-suffix>/...` |
| **FSLogix** | `FSLogix.zip` | `aka.<env-suffix>/FSLogix_latest` |

> **Note:** The AVD Agent and Bootloader are not used during custom image builds — they are included in this upload so that `agentDownloadUrl` and `agentBootLoaderDownloadUrl` host pool parameters can reference them from the artifacts storage account instead of relying on the permalink.

If these URLs are not reachable from your management system, download the files manually from the appropriate air-gapped cloud software distribution site and place them in `customer/artifacts/` before running with `-SkipDownloadingNewSources`.

---

### Upload Artifacts to Storage

After placing manual files and (optionally) allowing the script to download air-gapped-URL items:

```powershell
Connect-AzAccount -Environment <YourAirGappedEnvironment>
Set-AzContext -Subscription "<subscription-id>"
cd C:\repos\FederalAVD\deployments

# If air-gapped URLs are reachable — download auto-downloadable items and upload everything:
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"

# If no internet/network downloads are possible — skip downloading, just package and upload:
.\Update-ImageArtifacts.ps1 `
    -StorageAccountResourceId "<artifactsStorageAccountResourceId>" `
    -SkipDownloadingNewSources
```

> The `artifactsStorageAccountResourceId` is an output of the imageManagement deployment. See [Quick Start — Step 2](quick-start.md#step-2-deploy-image-management-resources).

---

### Image Build Parameter Notes

In air-gapped environments, set `downloadLatestMicrosoftContent = false` (default). The build VM will not have internet access to download software — all content must come from the artifacts storage account pre-populated above.

📖 **Full script reference:** [Update-ImageArtifacts.ps1 Script Guide](update-image-artifacts.md)
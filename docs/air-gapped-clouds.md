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
| --- | --- |
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
| --- | --- | --- | --- |
| **WebView2 Runtime** | `WebView2.exe` | `customer/artifacts/` | Required by Teams. Download from [go.microsoft.com/fwlink/?linkid=2124703](https://go.microsoft.com/fwlink/?linkid=2124703) on an internet-connected system. |
| **Visual Studio Redistributables** | `vc_redist.x64.exe` | `customer/artifacts/` | Required by Teams. Download from [aka.ms/vs/17/release/vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe) on an internet-connected system. |
| **Remote Desktop WebRTC Service** | `MsRdcWebRTCSvc.msi` | `customer/artifacts/` | Required for Teams media optimizations. Download from [aka.ms/msrdcwebrtcsvc/msi](https://aka.ms/msrdcwebrtcsvc/msi) on an internet-connected system. |
| **Microsoft Edge Enterprise** | `MicrosoftEdgeEnterpriseX64.msi` | `customer/artifacts/Microsoft-Edge-Enterprise/` | Optional. Download the Stable x64 MSI from [microsoft.com/en-us/edge/business/download](https://www.microsoft.com/en-us/edge/business/download) on an internet-connected system. On connected builds, `Install-MicrosoftEdgeEnterprise.ps1` downloads this automatically at image build time if no MSI is pre-staged — no manual step needed when internet access is available. |

> **Transfer tip:** Download all of the above on an internet-connected system, copy them to the air-gapped network, then drop them into the `customer/artifacts/` directory before running the upload script.

---

### Items Downloaded Automatically from Air-Gapped Network URLs

The following artifacts have working URLs in the secret and top secret downloads files (using air-gapped cloud endpoints). `Update-ImageArtifacts.ps1` downloads them automatically when the URLs are reachable from the management system:

| Software | Destination Filename | Air-Gapped URL Pattern |
| --- | --- | --- |
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

.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

The script automatically detects the connected environment and selects the correct base downloads file (`secret` or `topsecret`). Items with working air-gapped cloud URLs (AVD Agent, FSLogix, Teams, OneDrive, Office ODT) are downloaded automatically. Items with empty `DownloadUrl` (WebView2, vc_redist, MsRdcWebRTCSvc) and manually staged files in `customer/artifacts/` are packaged and uploaded as-is without a download attempt.

> **If air-gapped network URLs are not reachable** from your management system, add `-SkipDownloadingNewSources` to skip all downloads and only package and upload what is already staged locally.

> The `artifactsStorageAccountResourceId` is an output of the imageManagement deployment. See [Quick Start — Step 2](quick-start.md#step-2-deploy-image-management-resources).

---

### Image Build Parameter Notes

In air-gapped environments, set `downloadLatestMicrosoftContent = false` (default). The build VM will not have internet access to download software — all content must come from the artifacts storage account pre-populated above.

---

### Windows Updates (air-gapped)

Air-gapped environments have two options for patching the golden image during an image build:

**Option 1 — WSUS (recommended when available)**

The image build template has native WSUS support. Set the following parameters in your image build parameter file:

```json
"updateService": { "value": "WSUS" },
"wsusServer":    { "value": "https://wsus.corp.contoso.com:8531" }
```

During the build, the image VM will contact your WSUS server and install all approved updates for its hardware group — no pre-staging or manual file handling required. This is the preferred path for organizations that already operate a WSUS server in the air-gapped enclave.

> **Note:** `installUpdates` defaults to `true`. Set it to `false` only if you want to skip the Windows Update step entirely (e.g., the image is already fully patched).

**Option 2 — Offline artifacts (no WSUS)**

When a WSUS server is not available, each security component is pre-staged manually on a machine
with internet access, transferred to the air-gapped network, and installed via its artifact during
the image build. No internet access is needed at image build time.

**Monthly update checklist — no WSUS**

On or after Patch Tuesday (second Tuesday of each month), refresh each of the following
components. Detailed steps for each are in the sub-sections below.

| Component | Artifact | Source |
| --- | --- | --- |
| **Windows Cumulative Update** | `Windows-Catalog-Updates` | [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/) |
| **.NET Framework Cumulative Update** | `Windows-Catalog-Updates` | Microsoft Update Catalog |
| **.NET 8 / .NET 9 / .NET 10** *(if installed on image)* | `Windows-Catalog-Updates` | Microsoft Update Catalog |
| **Visual C++ Redistributable** | `Microsoft-VCRedistributable` | [`aka.ms` permalink](https://aka.ms/vs/17/release/vc_redist.x64.exe) — no KB, always re-download |
| **Microsoft Edge Enterprise** | `Microsoft-Edge-Enterprise` | [Edge Enterprise download page](https://www.microsoft.com/en-us/edge/business/download) — see [Microsoft Edge section](#microsoft-edge-air-gapped) below |

> **Office, Teams, OneDrive, FSLogix** are not part of this monthly rotation — they are installed
> from pre-staged installers and updated on their own schedules. See the sections below.

#### Windows, .NET Framework, and .NET runtime patches

Use the `Windows-Catalog-Updates` example artifact to install `.msu` patch files downloaded from
the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/). No internet access is
required at image build time.

📖 **Artifact reference:** [Windows-Catalog-Updates README](../customer-examples/artifacts/Windows-Catalog-Updates/README.md) — includes full instructions for finding KB numbers and downloading from the Catalog.

Download the following from a system with internet access and stage them in
`customer/artifacts/Windows-Catalog-Updates/` using numeric prefixes to control installation
order:

| Prefix | What to download | How to find it |
| --- | --- | --- |
| `01-CU-KB#####-x64.msu` | **Cumulative Update** for your Windows version | Search the Catalog for your OS (e.g., `windows 11, version 24H2 for x64`). Pick the current-month `B`-channel row from the [Windows 11 release health page](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information). |
| `02-dotNETFW-KB#####-x64.msu` | **.NET Framework Cumulative Update** | Open any recent KB article for your OS — e.g., [KB5101001 for Windows 11 24H2 (July 2026)](https://support.microsoft.com/en-us/servicing/dotnetframework/windows-11/24h2/2026/07/july-14-2026-kb5101001-cumulative-update-for-net-framework-3-5-and-4-8-1-for-windows-11-version-24h2) — then use the left-hand navigation to select the latest non-preview month. Search the Catalog for that KB number. |
| `03-dotNET8-KB#####-x64.msu` *(if applicable)* | **.NET 8 / .NET 9 / .NET 10 runtime security update** | Search the Catalog for `YYYY-MM .net` (e.g., `2026-08 .net`). Only include if that runtime version is installed on the image — run `dotnet --list-runtimes` on the current image to check. |

> **Servicing Stack Update (SSU):** Windows 11 24H2 and Windows 10 21H2+ bundle the SSU inside
> the monthly CU — a separate SSU file is not required unless the Windows release health page
> lists a standalone SSU with a release date newer than the CU. See the
> [Windows-Catalog-Updates README](../customer-examples/artifacts/Windows-Catalog-Updates/README.md)
> for full SSU guidance.

**Folder layout example:**

```text
customer\artifacts\Windows-Catalog-Updates\
    Install-WindowsCatalogUpdates.ps1
    01-CU-KB5058411-x64.msu
    02-dotNETFW-KB5058413-x64.msu
    03-dotNET8-KB5058414-x64.msu        <- only if .NET 8 is installed on the image
```

**To stage and upload each month:**

1. Download the required `.msu` files from the Catalog (see table above).
2. Copy the `Windows-Catalog-Updates` folder to the air-gapped network under `customer/artifacts/`.
3. Upload to the artifacts storage account:

   ```powershell
   .\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
   ```

   > **If network downloads are not reachable,** add `-SkipDownloadingNewSources` to skip the download step and only package and upload what is already staged locally.

> **Refresh cadence:** Replace patch files each month. The script installs all files present in the
> folder and skips already-installed patches via exit code — including a superseded patch is harmless.

#### Visual C++ Redistributable

<a id="visual-c-redistributable-air-gapped"></a>

The `Microsoft-VCRedistributable` example artifact installs the Visual C++ Redistributable during
an image build. Unlike Windows patches, there is no KB number or fixed Patch Tuesday cadence —
Microsoft does not publish a version number or changelog on the
[download page](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170).
The `aka.ms` permalink always serves the latest release, so the correct approach is to
re-download before every image build.

📖 **Artifact reference:** [Microsoft-VCRedistributable README](../customer-examples/artifacts/Microsoft-VCRedistributable/README.md)

**To pre-stage and upload before each image build:**

1. On a machine with internet access, download the latest installer:

   ```text
   https://aka.ms/vs/17/release/vc_redist.x64.exe
   ```

   Also download `https://aka.ms/vs/17/release/vc_redist.x86.exe` if 32-bit applications on
   the image require it.

2. Place the file(s) in the artifact folder:

   ```text
   customer\artifacts\Microsoft-VCRedistributable\
       Install-MicrosoftVCRedistributable.ps1
       vc_redist.x64.exe
   ```

3. Copy the folder to the air-gapped network under `customer/artifacts/`.

4. Upload to the artifacts storage account:

   ```powershell
   .\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
   ```

   > **If network downloads are not reachable,** add `-SkipDownloadingNewSources` to skip the download step.

> **Refresh cadence:** Re-download before every image build. If the image already has a newer
> release installed, the installer exits with code `1638` (already current) and no change is
> made — re-downloading every build is safe and ensures you are never behind.

---

### Microsoft Edge (air-gapped)

The `Microsoft-Edge-Enterprise` example artifact installs the Edge Enterprise MSI during an image build. In connected environments, `Update-ImageArtifacts.ps1` downloads the installer automatically from Microsoft. In air-gapped environments, you pre-stage the installer manually.

> **WSUS alternative:** If your WSUS server has the **Microsoft Edge** product category enabled and approved, Edge updates will be installed automatically during the Windows Update step of the image build — no artifact needed. Check WSUS → Products and Classifications → Products → Microsoft Edge to confirm. If Edge is not synced through WSUS, use the artifact below.

📖 **Artifact reference:** [Microsoft-Edge-Enterprise README](../customer-examples/artifacts/Microsoft-Edge-Enterprise/README.md)

**To use in an air-gapped image build:**

1. On any system with internet access, download the Edge Enterprise MSI from the [Microsoft Edge Enterprise download page](https://www.microsoft.com/en-us/edge/business/download):
   - Architecture: **x64**
   - Channel: **Stable**
   - File type: **MSI**

2. Place the MSI in the artifact folder alongside the install script:

   ```text
   customer\artifacts\Microsoft-Edge-Enterprise\
       Install-MicrosoftEdgeEnterprise.ps1
       MicrosoftEdgeEnterpriseX64.msi
   ```

3. Copy the folder to the air-gapped network and place it under `customer/artifacts/`.

4. Upload to the artifacts storage account:

   ```powershell
   .\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
   ```

   > **If network downloads are not reachable,** add `-SkipDownloadingNewSources` to skip the download step.

> **Refresh cadence:** Replace the MSI with the latest stable release monthly, then repeat steps 3-4. The script detects the installed version and skips installation if Edge is already up to date.

---

### Microsoft 365 Apps, Teams, and OneDrive (air-gapped)

<a id="microsoft-365-apps-teams-and-onedrive-air-gapped"></a>

> **Custom image is required.** In air-gapped clouds, Microsoft 365 Apps (Office), New Teams for VDI, and OneDrive cannot be reliably installed at session host runtime — AGC has specific offline installation requirements for these products, and the runtime environment on a session host does not satisfy them. **Baking these into a custom image is the correct and supported approach.** This solution handles the offline installation automatically once you stage the installers.

#### Why a custom image is required

The Microsoft documentation for Microsoft 365 Apps in Azure Government Classified (AGC) environments calls out specific installation methods, channel configurations, and activation endpoints that differ from commercial and unclassified government deployments. Installing Office at session host runtime (post-image) is not a supported path in these environments. The same applies to New Teams (which requires WebView2, Visual C++ Redistributables, and the RTC service to be present before Teams is installed) and OneDrive (which must be installed per-machine for VDI).

> For the authoritative Microsoft guidance, refer to the Microsoft 365 Apps documentation available on your air-gapped cloud's internal Microsoft Docs site or through your Microsoft account team.

#### How this solution handles it

The image build template has first-class support for M365 Apps, Teams, and OneDrive via dedicated parameters:

| Parameter | Description | Typical Value (air-gapped) |
| --- | --- | --- |
| `office365AppsToInstall` | M365 apps to install (Excel, Outlook, Word, etc.) | `["Excel", "Outlook", "PowerPoint", "Word"]` |
| `installOneDrive` | Install OneDrive per-machine for VDI | `true` |
| `installTeams` | Install New Teams for VDI | `true` |
| `teamsCloudType` | Teams cloud variant | `GovSecret` for Azure Government Secret (IL6); `GovTopSecret` for Azure Government Top Secret (IL7) |
| `downloadLatestMicrosoftContent` | Download from web instead of storage account | `false` — **do not change this** in air-gapped environments |

When `downloadLatestMicrosoftContent` is `false` (the default), the image build VM downloads all Microsoft content from the artifacts storage account. The Office 365 Deployment Tool, Teams bootstrapper, Teams MSIX, and OneDrive setup are all auto-downloadable from air-gapped cloud endpoints by `Update-ImageArtifacts.ps1`.

#### Artifacts to stage

The following files are fetched automatically by `Update-ImageArtifacts.ps1` from air-gapped cloud endpoints:

| File | Auto-downloaded | Notes |
| --- | :---: | --- |
| `Office365DeploymentTool.exe` | Yes | ODT; drives M365 Apps install |
| `OneDriveSetup.exe` | Yes | Per-machine OneDrive for VDI |
| `teamsbootstrapper.exe` | Yes | New Teams bootstrapper |
| `MSTeams-x64.msix` | Yes | New Teams MSIX package |

The following are **required by Teams** and must be staged manually:

| File | Place In | Source |
| --- | --- | --- |
| `WebView2.exe` | `customer/artifacts/` | [go.microsoft.com/fwlink/?linkid=2124703](https://go.microsoft.com/fwlink/?linkid=2124703) |
| `vc_redist.x64.exe` | `customer/artifacts/` | [aka.ms/vs/17/release/vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe) |
| `MsRdcWebRTCSvc.msi` | `customer/artifacts/` | [aka.ms/msrdcwebrtcsvc/msi](https://aka.ms/msrdcwebrtcsvc/msi) |

Download all three on an internet-connected system, copy them to the air-gapped network, and place them in `customer/artifacts/` before running `Update-ImageArtifacts.ps1`.

#### Image build parameter notes

```json
"office365AppsToInstall":          { "value": ["Excel", "Outlook", "PowerPoint", "Word"] },
"installOneDrive":                 { "value": true },
"installTeams":                    { "value": true },
"teamsCloudType":                  { "value": "GovSecret" },    // GovTopSecret for Azure Government Top Secret (IL7)
"downloadLatestMicrosoftContent":  { "value": false }
```

> **`vdiOptimizationRestrictInternet`** — set this to `true` in air-gapped image builds. It locks down update channels for M365, Teams, OneDrive, Edge, WebView2, and the Windows Store so these apps do not attempt to phone home after deployment.

📖 **Image build parameter reference:** [image-build.md — Built-in Microsoft content](image-build.md#image-build-parameters)

---

📖 **Full script reference:** [Update-ImageArtifacts.ps1 Script Guide](update-image-artifacts.md)

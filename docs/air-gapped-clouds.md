↩ **Back to:** [Quick Start](quick-start.md)

[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Host Pool Deployment**](hostpool-deployment.md) | [**Image Build**](image-build.md) | [**Artifacts**](artifacts-guide.md) | [**Features**](features.md) | [**Parameters**](parameters.md) | [**Compliance**](compliance.md) | [**BCDR**](bcdr.md)

# Air-Gapped Cloud Considerations

Use this guide for Azure Government Secret and Azure Government Top Secret. Begin by choosing the
deployment path, then inventory every build-time and session-host runtime dependency. Software and
service endpoints available in one enclave might not be reachable from another.

Use a **standard host pool** in these clouds. FederalAVD's automated host pool uses a Commercial-only
preview service. See [Choose a Host Pool Management Approach](host-pool-management.md) before
deploying Step 4.

## Choose the Image Path

A custom image is not universally required. Choose the smallest path that meets the workload:

| Workload | Image path | Required FederalAVD steps |
| --- | --- | --- |
| Windows only; suitable marketplace SKU is available; no additional software or image-time configuration | Verified marketplace image | Standard Host Pool; add Networking and Shared Services when the architecture requires them |
| Microsoft 365 Apps, Teams, OneDrive, software unavailable in the target cloud, or substantial preconfiguration | Custom Compute Gallery image | Image Management, Image Build, then Standard Host Pool |

Marketplace-image suitability does not prove session-host readiness. In either path, verify the
target enclave can reach the authoritative AVD service endpoints and can obtain the AVD Agent and
Boot Loader from cloud-native or internally hosted sources. Verify the exact marketplace publisher,
offer, and SKU in the target cloud before selecting the shorter path.

## Configure and Connect With Azure PowerShell

Before publishing Template Specs, configure Azure PowerShell for the target cloud and connect to the
deployment subscription. The cloud-specific Microsoft Learn articles provide the authorized values
and commands required to register the environment with `Add-AzEnvironment`, connect with
`Connect-AzAccount`, and select the subscription:

- **[Connect to Azure Government Secret using PowerShell](https://review.learn.microsoft.com/en-us/microsoft-government-secret/azure/azure-government-secret/quick-starts/documentation-government-secret-get-started-azure-powershell-connect?branch=live)**
- **[Connect to Azure Government Top Secret using PowerShell](https://review.learn.microsoft.com/en-us/microsoft-government-topsecret/azure/azure-government-top-secret/quickstarts/documentation-government-top-secret-get-started-powershell-connect?branch=live)**

> **Access note:** These PowerShell connection references are available only to authorized Microsoft
> employees. This public repository intentionally does not reproduce environment names, endpoints,
> or locations. If you cannot access the links, use the Microsoft Learn content available inside the
> target environment or contact the environment support team.

## First Deployment Checklist

Use this sequence for the first deployment. The sections later in this guide provide the package
inventories and parameter details for each step.

1. **Prepare the deployment workstation.** Transfer this repository to an approved management
   workstation that can reach the target Azure environment. Separately transfer required installers
   and policy templates from an approved connected system into the matching
   `customer/artifacts/<FolderName>/` directories. Do not edit files under `customer-examples/`.
2. **Configure and connect with Azure PowerShell.** Follow the applicable
   [PowerShell connection article](#configure-and-connect-with-azure-powershell) to register the
   target cloud with `Add-AzEnvironment` and connect with `Connect-AzAccount`. Select the deployment
   subscription and verify the context before continuing. The placeholders below intentionally do
   not reproduce restricted environment values:

   ```powershell
   Get-AzEnvironment | Select-Object Name, ResourceManagerUrl
   Connect-AzAccount -Environment '<environment-name>'
   Set-AzContext -Subscription '<subscription-id>'
   Get-AzContext | Select-Object Name, Subscription, Environment
   ```

3. **Publish the guided portal forms.** After the PowerShell context shows the intended environment
   and subscription, run the publishing script from the repository root. It uses that active context
   to publish the core Template Specs into the target subscription. Publishing creates the forms; it
   does not deploy the workloads:

   ```powershell
   .\tools\New-TemplateSpecs.ps1 `
      -Location '<region>' `
      -createNetwork $true `
      -createSharedServices $true `
      -createImageManagement $true `
      -createCustomImage $true `
      -createHostPool $true `
      -CreateAddOns $false
   ```

   Set `-createImageManagement` and `-createCustomImage` to `$false` when the verified marketplace
   image path meets the workload. Automated host pools are not supported in these clouds.

4. **Deploy prerequisites through Template Specs.** Deploy Networking only when an existing VNet
   and subnet are unavailable. For IL6 and IL7, deploy AVD Shared Services by default to
   establish centralized audit collection, operational monitoring, secrets protection, and key
   management before workload resources are created. Omit it only when the approved architecture
   already provides equivalent Key Vault, Log Analytics Workspace, DCR, DCE, diagnostic-settings,
   and key-management capabilities, and the control owners have documented how those shared
   services satisfy the applicable requirements. AVD Shared Services is a hard sequencing
   dependency before Image Management when artifact/build-log storage or gallery image versions
   use CMK, or when policy requires an existing Log Analytics Workspace.
   At **Review + create**, download each generated parameter file and save it under the matching
   `customer/parameters/` folder as described in the
   [Quick Start workflow](quick-start.md#recommended-first-deployment-workflow).
5. **Deploy Image Management when a custom image is required.** Retain its
   `artifactsStorageAccountResourceId` output along with
   these output-to-input values required by Image Build:

   | Image Management output | Image Build parameter |
   | --- | --- |
   | `computeGalleryResourceId` | `computeGalleryResourceId` |
   | `artifactsBlobContainerUrl` | `artifactsContainerUri` |
   | `managedIdentityResourceId` | `userAssignedIdentityResourceId` |
   | `buildLogsStorageAccountResourceId` | `logStorageAccountResourceId` |
   | `imageBuildResourceGroupResourceId` | `imageBuildResourceGroupId` |

6. **For a custom image, complete the artifact inventory and upload.** Review the
   [manual items](#items-that-must-be-placed-manually), the
   [air-gapped URL items](#items-downloaded-automatically-from-air-gapped-network-urls), and any
   copied customer-example artifacts. Upload the staged content:

   ```powershell
   .\deployments\Update-ImageArtifacts.ps1 `
       -StorageAccountResourceId '<artifactsStorageAccountResourceId>'
   ```

   Add `-SkipDownloadingNewSources` when the management workstation cannot reach the approved
   air-gapped software distribution endpoints.
   To deploy selected packages after VM creation, verify that Compute Gallery VM Applications are
   available in the target cloud and continue with the
   [VM Application publishing guide](vm-applications.md). The publisher uses only pre-staged blobs,
   managed identity, and the active cloud's storage endpoint suffix.
7. **Build the custom image when required.** In the Custom Image Template Spec form, use the outputs from Image
   Management. On **Image Customizations**, set **Download Microsoft Sources from Web** to **No**
   (`downloadLatestMicrosoftContent = false`). Under **VDI Optimizations**, select **Air-gapped /
   restricted network** (`vdiOptimizationAirGapped = true`). Install all software from the uploaded
   artifacts, save the generated parameters under `customer/parameters/imageBuild/`, and retain
   `customImageResourceId`.
8. **Deploy the standard host pool.** Select either the verified marketplace image or the custom
   gallery image. Provide internally hosted
   `agentDownloadUrl` and `agentBootLoaderDownloadUrl` values when the default cloud endpoints are
   unavailable as described under [Session Host Deployment](#session-host-deployment), save the
   generated parameters under `customer/parameters/hostpools/`, and deploy.
9. **Verify without public dependencies.** Confirm session hosts report **Available**, users can
   launch the required applications, and no image-build or session-host step attempted to reach a
   public internet endpoint.

Blue Button links are not available in Secret or Top Secret. Use Template Specs for the guided
first deployment and the saved parameter files for later PowerShell or CI/CD deployments.

> **Compliance posture:** The templates do not grant an authorization or certification. Step 1 is
> the recommended IL6/IL7 baseline because its logging, monitoring, secrets, and key-management
> capabilities provide implementation evidence for controls including AU-2, AU-3, AU-12, SI-4,
> IA-5, and SC-12. An authorizing official or control owner must validate any equivalent shared
> services and residual gaps. See [Compliance](compliance.md).

## Network Requirements & Documentation

Use the references below when designing routing, firewall rules, private endpoints, DNS, and service
connectivity. They are grouped by purpose so the PowerShell connection articles above remain focused
on configuring the Az environment and publishing Template Specs.

### General Cloud Environment Differences

These cloud-wide references document service availability and differences from global Azure,
including cloud-specific portals, endpoints, and service behavior:

- **[Azure Government Secret differences from global Azure](https://review.learn.microsoft.com/en-us/microsoft-government-secret/azure/azure-government-secret/overview/azure-government-secret-differences-from-global-azure?branch=live)**
- **[Azure Government Top Secret differences from global Azure](https://review.learn.microsoft.com/en-us/microsoft-government-topsecret/azure/azure-government-top-secret/overview/azure-government-top-secret-differences-from-global-azure?branch=live)**

### Azure Virtual Desktop Service Requirements

Session hosts require access to Azure Virtual Desktop service endpoints, including the AVD Agent
installer sources and service FQDNs. Use the cloud-specific AVD references for the authoritative
network requirements, required URLs, and installer permalinks:

- **[Azure Government Secret AVD Service Documentation](https://review.learn.microsoft.com/en-us/microsoft-government-secret/azure/azure-government-secret/services/virtual-desktop-infrastructure/virtual-desktop?branch=live)** - Includes required endpoints and AVD Agent installer download URLs
- **[Azure Government Top Secret AVD Service Documentation](https://review.learn.microsoft.com/en-us/microsoft-government-topsecret/azure/azure-government-top-secret/services/virtual-desktop-infrastructure/virtual-desktop?branch=live)** - Includes required endpoints and AVD Agent installer download URLs

### Private Endpoint DNS

The FederalAVD Networking Template Spec is the supported way to create missing private DNS zones.
Its Bicep derives cloud-specific names from the connected Azure environment and maintained mappings,
so operators do not need to reproduce protected Secret or Top Secret values. In the form, select
existing enterprise zones or choose **Deploy any missing Private DNS Zones**, link them to the new
or existing VNet, and retain the `privateDnsZoneResourceIds` output for later deployments.

Create or select only the zones required by enabled features:

| Networking parameter | Required when |
| --- | --- |
| `createAzureBackupZone` | Azure Backup uses a private endpoint |
| `createAzureBlobZone` | Blob storage uses a private endpoint |
| `createAzureFilesZone` | Azure Files, including FSLogix storage, uses a private endpoint |
| `createAzureQueueZone` | Queue storage uses a private endpoint |
| `createAzureTableZone` | Table storage uses a private endpoint |
| `createAzureKeyVaultZone` | Key Vault uses a private endpoint |
| `createAvdFeedZone` | AVD Private Link is enabled for the workspace feed or connections |
| `createAvdGlobalFeedZone` | AVD Private Link is enabled for global feed discovery |
| `createAzureWebAppZone` | Function Apps or Web Apps use a private endpoint |

Every private endpoint needs a matching zone linked to the workload VNet or to the DNS resolver
serving that VNet. Private endpoints are not a substitute for DNS configuration.

The employee-only Microsoft references below remain authoritative for validating the resulting
zone values and target-cloud behavior. Do not reuse Azure Commercial or Azure Government zone names
in Secret or Top Secret:

- **[Azure Government Secret private endpoint DNS](https://review.learn.microsoft.com/microsoft-government-secret/azure/azure-government-secret/services/networking/private-link/private-endpoint-dns)**
- **[Azure Government Top Secret private endpoint DNS](https://review.learn.microsoft.com/microsoft-government-topsecret/azure/azure-government-top-secret/services/networking/private-link/private-endpoint-dns)**

> **Access note:** These references are available only to authorized Microsoft employees. This
> repository intentionally does not reproduce restricted endpoints, required URL lists, private DNS
> zone values, or locations. If you cannot access the links, use Microsoft Learn inside the target
> environment or contact the environment support team.

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

📖 **Parameter Reference:** See
[Host Pool Deployment - Air-Gapped Cloud Support](hostpool-deployment.md#air-gapped-cloud-support).

---

## Custom Image Build

> **Use this section when the workload requires a custom image.** Microsoft 365 Apps, Teams,
> OneDrive, software unavailable in the target cloud, and substantial preconfiguration should be
> installed in the golden image because public internet downloads are unavailable at session-host
> runtime. A plain Windows workload may instead use a marketplace image after its SKU and AVD
> bootstrap dependencies are verified in the target cloud. For M365-specific requirements, see
> [Microsoft 365 Apps, Teams, and OneDrive](#microsoft-365-apps-teams-and-onedrive-air-gapped).

### How the Downloads Configuration Works

The `Update-ImageArtifacts.ps1` script automatically selects the correct downloads configuration file from `.common/data/` based on the connected Azure environment:

| Azure Environment | Base File |
| --- | --- |
| AzureCloud / AzureUSGovernment | `.common/data/public.downloads.parameters.json` |
| Azure Government Secret (IL6) | `.common/data/secret.downloads.parameters.json` |
| Azure Government Top Secret (IL7) | `.common/data/topsecret.downloads.parameters.json` |

The secret and top secret files are already in the repository. Each entry either has a working air-gapped cloud URL (the script downloads it automatically) or an **empty `DownloadUrl`** (you must place the file manually before running the script).

To add software not in the base file, place `downloads.json` in `customer/parameters/imageManagement/`. The script discovers and merges it automatically. See [Update-ImageArtifacts Script Guide](update-image-artifacts.md) for the file format.

> **⚠️ WingetId entries are not supported in air-gapped environments.** Winget requires outbound internet access to the Microsoft Store CDN, which is unavailable in air-gapped clouds. The base `secret` and `topsecret` downloads files do not use winget, so a standard run of `Update-ImageArtifacts.ps1` is unaffected.
>
> **Keep your air-gapped `customer/parameters/imageManagement/downloads.json` free of `WingetId` entries.** Only include `DownloadUrl` entries pointing to URLs reachable from your management system. For built-in UWP apps and codec extensions, see [Built-in UWP apps and codec extensions](#built-in-uwp-apps-and-codec-extensions) in the Windows Updates section below.
>
> For other software that uses `WingetId`, alternatives include:
>
> - Replacing `WingetId` with a `DownloadUrl` pointing to an internally hosted copy.
> - Pre-staging the installer in `customer/artifacts/<FolderName>/` and omitting the entry from `downloads.json` — the script packages and uploads it without attempting a download.

---

### Customer-Example Artifacts With Public Download Sources

`customer-examples/parameters/imageManagement/downloads.json` (a separate, optional overlay
file — distinct from the repo's built-in `secret`/`topsecret` base files above) contains
`DownloadUrl`/`GitHubRepo` entries pointing at public internet endpoints (GitHub, vendor CDNs,
Microsoft/Google update services, etc.). None of these are reachable from air-gapped
management systems. This affects every example artifact you copy from
`customer-examples/artifacts/`, including the browser policy configuration scripts:

| Artifact | What to pre-stage | Public source (download on a connected system) |
| --- | --- | --- |
| [Configure-EdgePolicy](../customer-examples/artifacts/Configure-EdgePolicy/README.md) | `MicrosoftEdgePolicyTemplates.cab` | Edge Updates API; use the README's PowerShell resolver because the API endpoint is not the CAB URL |
| [Configure-ChromePolicy](../customer-examples/artifacts/Configure-ChromePolicy/README.md) | Chrome Enterprise ADMX/ADML ZIP | `https://dl.google.com/dl/edgedl/chrome/policy/policy_templates.zip` |
| [Configure-Office365Policy](../customer-examples/artifacts/Configure-Office365Policy/README.md) | `AdminTemplates_x64.exe` | Microsoft Download Center; use the current direct URL and PowerShell command in the README |

The example `downloads.json` is the maintained inventory of public sources and destination
filenames. On a connected management system, it can download and package all three items
automatically. Do not run those public download entries from an air-gapped management system.
Instead, use each artifact README to download the package on a connected workstation, transfer
it into the matching `customer/artifacts/Configure-*Policy/` folder, and run
`Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`. Each policy script prefers its bundled
package, so no public network access is needed during the image build.

The other Configure policy examples do not require a separately downloaded template package:

| Artifact | Template source |
| --- | --- |
| [Configure-OneDriveKFMPolicy](../customer-examples/artifacts/Configure-OneDriveKFMPolicy/README.md) | Copies `OneDrive.admx` and its ADML files from the installed OneDrive client |
| [Configure-RemoteDesktopPolicy](../customer-examples/artifacts/Configure-RemoteDesktopPolicy/README.md) | Uses Remote Desktop policy definitions included with Windows |
| [Configure-WindowsUpdatePolicy](../customer-examples/artifacts/Configure-WindowsUpdatePolicy/README.md) | Uses Windows Update policy definitions included with Windows |

For any other customer-example artifact, follow the general pattern: download the file on an
internet-connected system, place it in `customer/artifacts/<FolderName>/`, and run
`Update-ImageArtifacts.ps1 -SkipDownloadingNewSources` so the script packages and uploads what
is already staged without attempting a download.

---

### Items That Must Be Placed Manually

The following artifacts have empty `DownloadUrl` entries in the secret and top secret downloads files — no automated download source is configured. If you wish, you can obtain these files from a reachable source (internet-connected system, Azure Toolbox, vendor portal, etc.) and place them at the paths shown before running `Update-ImageArtifacts.ps1`.

| Software | Destination Filename | Place In | Notes |
| --- | --- | --- | --- |
| **WebView2 Runtime** | `WebView2.exe` | `customer/artifacts/` | Required by Teams. Download from [go.microsoft.com/fwlink/?linkid=2124703](https://go.microsoft.com/fwlink/?linkid=2124703) on an internet-connected system. |
| **Visual Studio Redistributables** | `vc_redist.x64.exe` | `customer/artifacts/` | Required by Teams. Download from [aka.ms/vs/17/release/vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe) on an internet-connected system. |
| **Remote Desktop WebRTC Service** | `MsRdcWebRTCSvc.msi` | `customer/artifacts/` | Required for Teams media optimizations. Download from [aka.ms/msrdcwebrtcsvc/msi](https://aka.ms/msrdcwebrtcsvc/msi) on an internet-connected system. |

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
Connect-AzAccount -Environment '<environment-name>'
Set-AzContext -Subscription "<subscription-id>"
cd C:\repos\FederalAVD\deployments

.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

The script automatically detects the connected environment and selects the correct base downloads file (`secret` or `topsecret`). Items with working air-gapped cloud URLs (AVD Agent, FSLogix, Teams, OneDrive, Office ODT) are downloaded automatically. Items with empty `DownloadUrl` (WebView2, vc_redist, MsRdcWebRTCSvc) and manually staged files in `customer/artifacts/` are packaged and uploaded as-is without a download attempt.

> **If air-gapped network URLs are not reachable** from your management system, add `-SkipDownloadingNewSources` to skip all downloads and only package and upload what is already staged locally.

The `artifactsStorageAccountResourceId` is an output of the imageManagement deployment. See [Quick Start — Step 2](quick-start.md#step-2-deploy-image-management-resources).

---

### Image Build Parameter Notes

In air-gapped environments, set `downloadLatestMicrosoftContent = false` (default). The build VM will not have internet access to download software — all content must come from the artifacts storage account pre-populated above.

---

### Windows Updates (air-gapped)

Air-gapped environments have two options for patching the golden image during an image build:

#### Option 1 - WSUS (Recommended When Available)

The image build template has native WSUS support. Set the following parameters in your image build parameter file:

```json
"updateService": { "value": "WSUS" },
"wsusServer":    { "value": "https://wsus.corp.contoso.com:8531" }
```

During the build, the image VM will contact your WSUS server and install all approved updates for its hardware group — no pre-staging or manual file handling required. This is the preferred path for organizations that already operate a WSUS server in the air-gapped enclave.

> **Note:** `installUpdates` defaults to `true`. Set it to `false` only if you want to skip the Windows Update step entirely (e.g., the image is already fully patched).

**Note:** WSUS patches OS components and Win32 applications but does **not** update built-in UWP apps (Calculator, Notepad, Snipping Tool, etc.). See [Built-in UWP apps and codec extensions](#built-in-uwp-apps-and-codec-extensions) below for the separate update workflow required regardless of which patching option you use.

#### Option 2 - Offline Artifacts (No WSUS)

When a WSUS server is not available, each security component is pre-staged manually on a machine
with internet access, transferred to the air-gapped network, and installed via its artifact during
the image build. No internet access is needed at image build time.

##### Monthly Update Checklist - No WSUS

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

> **Reboot required after patch installation:** Windows cumulative updates almost always
> require a reboot to finish applying. Set **`"restart": true`** on the
> `Windows-Catalog-Updates` entry in your image build `customizations` parameter so the
> build VM reboots before subsequent steps run:
>
> ```json
> {
>   "name": "Windows-Catalog-Updates",
>   "blobNameOrUri": "Windows-Catalog-Updates.zip",
>   "restart": true
> }
> ```

**Refresh cadence:** Replace patch files each month. The script installs all files present in the
folder and skips already-installed patches via exit code — including a superseded patch is harmless.

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

#### Built-in UWP apps and codec extensions

> **WSUS does not update built-in UWP apps.** Windows Update and WSUS patch OS components and
> Win32 applications but do not update Store-distributed UWP apps such as Calculator, Notepad,
> Snipping Tool, Clipchamp, or codec extensions. Keeping these apps current — for new
> functionality or to mitigate Store-app vulnerabilities — requires the workflow below,
> regardless of which patching option above you use.

The `BuiltIn-UWP-Apps` artifact (Calculator, Paint, Snipping Tool, Notepad, Clipchamp, Photos,
Sticky Notes, Windows Terminal, and codec extensions) uses `WingetId` entries that require
internet access. The recommended approach is to build the artifact zip on a connected machine,
transfer only the zip to the air-gapped side, and upload it directly.

##### Step 1 - Build the Zip on a Connected Machine

1. Copy the artifact folder and example downloads file into the connected-side customer folder:

   ```powershell
   Copy-Item -Recurse -Path "customer-examples\artifacts\BuiltIn-UWP-Apps" `
       -Destination "customer\artifacts\" -Force

   Copy-Item -Path "customer-examples\parameters\imageManagement\downloads.json" `
       -Destination "customer\parameters\imageManagement\" -Force
   ```

   The artifact folder supplies `Install-BuiltinUwpApps.ps1`. The downloads file supplies the
   `WingetId` and `WingetPreserveLayout` entries for the apps and codec extensions. If you already
   maintain a customer downloads file, merge the preserve-layout entries into it instead of
   replacing it.

2. Run `Update-ImageArtifacts.ps1` in local package mode. This does not require an Azure login,
   subscription, or storage account:

   ```powershell
   .\Update-ImageArtifacts.ps1 `
       -PackageOnly `
       -OutputPath "C:\AirGapTransfer"
   ```

   The script downloads all winget packages, deduplicates shared dependencies, packages the
   `BuiltIn-UWP-Apps\` folder, and writes `C:\AirGapTransfer\BuiltIn-UWP-Apps.zip`.

   To use a connected Azure storage account instead, run the script with
   `-StorageAccountResourceId "<connectedStorageAccountResourceId>"`, then download
   `BuiltIn-UWP-Apps.zip` from its `artifacts` blob container.

##### Step 2 - Transfer to the Air-Gapped Network

DTA (low-to-high) `BuiltIn-UWP-Apps.zip` to the air-gapped network. Only the single zip file
needs to be transferred — the full folder structure with all MSIX packages and shared
dependencies is already inside it.

##### Step 3 - Upload to the Air-Gapped Storage Account

###### Option A - Script Upload (Recommended)

Place `BuiltIn-UWP-Apps.zip` in the **root** of `customer/artifacts/` on the air-gapped machine
(not inside a sub-folder):

```text
customer\artifacts\
    BuiltIn-UWP-Apps.zip    <- transferred zip, placed at root level
    Windows-Catalog-Updates\
    Microsoft-VCRedistributable\
    ...other folders...
```

Then run `Update-ImageArtifacts.ps1` normally — no extra flags needed:

```powershell
.\Update-ImageArtifacts.ps1 -StorageAccountResourceId "<artifactsStorageAccountResourceId>"
```

Because `BuiltIn-UWP-Apps.zip` is a root-level file (not a sub-folder), the script copies it
directly to the upload staging area without re-zipping and uploads it to the air-gapped storage
account. No winget access is attempted and `-SkipDownloadingNewSources` is not needed, as long
as your air-gapped `customer/parameters/imageManagement/downloads.json` contains only
`DownloadUrl` entries pointing to air-gapped-reachable URLs.

###### Option B - Manual Portal Upload

In the Azure Portal, navigate to the air-gapped artifacts storage account →
**Storage browser → Blob containers → artifacts** and upload `BuiltIn-UWP-Apps.zip` directly.

> **Refresh cadence:** Repeat steps 1-3 periodically to pick up updated app versions. The
> connected-side script run always pulls the latest versions available from the Store at the
> time it runs. MSIX packages include the app version in the filename.

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
      Deploy-MicrosoftEdgeEnterprise.ps1
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

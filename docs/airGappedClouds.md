↩ **Back to:** [Quick Start](quickStart.md)

[**Home**](../README.md) | [**Quick Start**](quickStart.md) | [**Host Pool Deployment**](hostpoolDeployment.md) | [**Image Build**](imageBuild.md) | [**Artifacts**](artifactsGuide.md) | [**Features**](features.md) | [**Parameters**](parameters.md)

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
- If `agentBootLoaderDownloadUrl` is empty (default) → uses the `https://aka.<cloudsuffix>/avdRDAgentBootLoader` permalink (see network requirements documentation above)

**AVD Agent:**

- If `useAgentDownloadEndpoint` is `true` (default):
  1. Attempts to download the latest agent version from the host pool API endpoint
  2. If endpoint fails → uses `agentDownloadUrl` (if provided) OR the `https://aka.<cloudsuffix>/avdRDAgent` permalink.
- If `useAgentDownloadEndpoint` is `false`:
  - Uses `agentDownloadUrl` (if provided) OR the `https://aka.<cloudsuffix>\avdRDAgent` permalink.

| Component | Storage Account</br>Provided | Instructions |
| :-- | :--: | :-- |
| **AVD Agent &</br>Boot Loader** | Yes | For air-gapped environments where the permalinks are not accessible:<ol><li>Download the latest AVD Agent Boot Loader and AVD Agent MSI files from a system where they are accessible.</li><li>Upload them to your artifacts storage account blob container with the original filenames (e.g., **Microsoft.RDInfra.RDAgentBootLoader.Installer-x64.msi** and **Microsoft.RDInfra.RDAgent.Installer-x64.msi**).</li><li>Configure the `agentBootLoaderDownloadUrl` and `agentDownloadUrl` parameters with the full URLs to the installers in blob storage to override the default permalinks.</li></ol>**Note:** When `useAgentDownloadEndpoint` is enabled (default), the Agent download tries the host pool API endpoint first, then falls back to your custom URL. See [Parameters](parameters.md) for details. |
| **AVD Agent &</br>Boot Loader** | No | The deployment uses the default cloud-specific permalinks (see network requirements above) for both components. For the Agent, if `useAgentDownloadEndpoint` is `true` (default), the deployment first attempts the host pool API endpoint for the latest version before falling back to the permalink. |

📖 **Parameter Reference:** See the `agentDownloadUrl`, `agentBootLoaderDownloadUrl`, and `useAgentDownloadEndpoint` parameters in [Parameters](parameters.md).

---

## Custom Image Build

The following table provides specific instructions for preparing your air-gapped environment for building custom images. This assumes that you have already created the image management storage account and blob container. The **Storage Account Provided** and **Download Latest Microsoft Content** columns represent the `artifactsContainerUri` and the `downloadLatestMicrosoftContent` image build parameters respectively.

| Software | Storage Account</br>Provided | Download Latest</br>Microsoft Content | Instructions and Caveats |
| :-- | :--: | :--: | :-- |
| FSLogix | Yes | Yes / No | **✅ Available in Azure Toolbox!** <ol><li>Within your air-gapped cloud, download the latest FSLogix installer from the Azure Toolbox.</li><li>Save it as **FSLogix.zip** in the storage account and container specified.</li></ol>**Note:** No internet access or cross-network file transfer required! Alternatively, you can still download from [aka.ms/fslogix_download](https://aka.ms/fslogix_download) on an internet-connected system and transfer it. |
| FSLogix | No | Yes / No | <span style="color:red">Not supported</span> - Storage account is required because automated script downloads from Azure Toolbox require authentication. |
| Office | Yes | No | On your air-gapped management system, execute [Deploy-ImageManagement.ps1](quickStart.md#deploy-image-management-resources) or download the Office Deployment Tool from the appropriate Microsoft 365 Apps link below and save it to the blob storage container as **Office365DeploymentTool.exe**. |
| Office | Yes / No | Yes | The air-gapped cloud Office Deployment Tool Setup.exe download url must be accessible from the image build virtual machine. |
| OneDrive | Yes | No |  On your air-gapped management system, execute [Deploy-ImageManagement.ps1](quickStart.md#deploy-image-management-resources) or download OneDriveSetup.exe from the appropriate air-gapped download url and save it as **OneDriveSetup.exe** in the blob container.|
| OneDrive | Yes / No | Yes | The appropriate Air-Gapped cloud OneDriveSetup.exe download url must be accessible from the image build virtual machine. |
| Teams | Yes | No | <ol><li>On a system with access to the public Internet:</br><ul><li>Download the latest [WebView2 Runtime](https://go.microsoft.com/fwlink/?linkid=2124703) and save it as **WebView2.exe**</li><li>Download the lastest [Visual Studio Redistributables](https://aka.ms/vs/17/release/vc_redist.x64.exe) and save it as **vc_redist.x64.exe**.</li><li>Download the latest [Remote Desktop Web RTC Service installer](https://aka.ms/msrdcwebrtcsvc/msi) and save it as **MsRdcWebRTCSvc.msi**.</li></ul><li>Transfer all three files to the air-gapped network and upload them to the storage account blob container.</li><li>On your air-gapped management system, execute [Deploy-ImageManagement.ps1](quickStart.md#deploy-image-management-resources) or  download:<ul><li>The latest Teams Bootstrapper from the appropriate air-gapped cloud Microsoft Teams reference site and upload it to the storage blob container as **teamsbootstrapper.exe**.</li><li>The latest Teams 64-bit MSIX file from appropriate Air-Gapped download sites and upload it to the storage blob container as **MSTeams-x64.msix**.</li></ul></ol> |
| Teams | Yes | Yes | <ol><li>On a system with access to the public Internet:</br><ul><li>Download the latest [WebView2 Runtime](https://go.microsoft.com/fwlink/?linkid=2124703) and save it as **WebView2.exe**.</li><li>Download the lastest [Visual Studio Redistributables](https://aka.ms/vs/17/release/vc_redist.x64.exe) and save it as **vc_redist.x64.exe**.</li><li>Download the latest [Remote Desktop Web RTC Service installer](https://aka.ms/msrdcwebrtcsvc/msi) and save it as **MsRdcWebRTCSvc.msi**.</li></ul><li>Transfer all three files to the air-gapped network and upload them to the storage account blob container.</li><li>Ensure that the image build virtual machine can access The latest Teams Bootstrapper and the latest Teams 64-bit MSIX file from appropriate air-gapped cloud Microsoft Teams download site. |
| Teams | No | Yes | Ensure that the image build virtual machine can access The latest Teams Bootstrapper and MSIX file downloads available on the Air-Gapped network. **Note:**<span style="color:red">Teams media optimizations will not be enabled in this scenario.</span> |
| Teams | No | No | <span style="color:red">Not supported</span> |
| WDOT | Yes | Yes / No | <ol><li>On a system with access to the public Internet, download the latest [WDOT](https://codeload.github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool/zip/refs/heads/main) and save it as **WDOT.zip**.</li><li>Transfer it to an air-gapped system and upload it to the storage account container. |
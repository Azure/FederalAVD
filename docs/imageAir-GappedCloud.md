[**Home**](../README.md) | [**Design**](design.md) | [**Get Started**](quickStart.md) | [**Troubleshooting**](troubleshooting.md) | [**Parameters**](parameters.md) | [**Scope**](scope.md) | [**Zero Trust Framework**](zeroTrustFramework.md)

# Air-Gapped Cloud Custom Image Build Considerations

The air-gapped clouds, Azure Government Secret and Azure Government Top Secret, offer unique challenges because not all software is available for download via http and where it is it may not be available to all enclaves on the networks these clouds service.

The following table provides specific instructions for preparing your air-gapped environment for building custom images. This assumes that you have already created the image management storage account and blob container. The **Storage Account Provided** and **Download Latest Microsoft Content** columns represent the `artifactsContainerUri` and the `downloadLatestMicrosoftContent` image build parameters respectively.

| Software | Storage Account</br>Provided | Download Latest</br>Microsoft Content | Instructions and Caveats |
|:--|:--:|:--:|:--|
| FSLogix | Yes | Yes / No | <ol><li>On a system with access to the public Internet, download the latest agent at [aka.ms/fslogix_download](https://aka.ms/fslogix_download).</li><li>Transfer it to the air-gapped cloud and save it as **FSLogix.zip** in the storage account and container specified.</li></ol> |
| FSLogix | No | Yes / No | <span style="color:red">Not supported</span> |
| Office | Yes | No | On your air-gapped management system, execute [Deploy-ImageManagement.ps1](quickStart.md#deploy-image-management-resources) or download the Office Deployment Tool from the appropriate Microsoft 365 Apps link below and save it to the blob storage container as **Office365DeploymentTool.exe**. |
| Office | Yes / No | Yes | The air-gapped cloud Office Deployment Tool Setup.exe download url must be accessible from the image build virtual machine. |
| OneDrive | Yes | No |  On your air-gapped management system, execute [Deploy-ImageManagement.ps1](quickStart.md#deploy-image-management-resources) or download OneDriveSetup.exe from the appropriate air-gapped download url and save it as **OneDriveSetup.exe** in the blob container.|
| OneDrive | Yes / No | Yes | The appropriate Air-Gapped cloud OneDriveSetup.exe download url must be accessible from the image build virtual machine. |
| Teams | Yes | No | <ol><li>On a system with access to the public Internet:</br><ul><li>Download the latest [WebView2 Runtime](https://go.microsoft.com/fwlink/?linkid=2124703) and save it as **WebView2.exe**</li><li>Download the lastest [Visual Studio Redistributables](https://aka.ms/vs/17/release/vc_redist.x64.exe) and save it as **vc_redist.x64.exe**.</li><li>Download the latest [Remote Desktop Web RTC Service installer](https://aka.ms/msrdcwebrtcsvc/msi) and save it as **MsRdcWebRTCSvc.msi**.</li></ul><li>Transfer all three files to the air-gapped network and upload them to the storage account blob container.</li><li>On your air-gapped management system, execute [Deploy-ImageManagement.ps1](quickStart.md#deploy-image-management-resources) or  download:<ul><li>The latest Teams Bootstrapper from the appropriate air-gapped cloud Microsoft Teams reference site and upload it to the storage blob container as **teamsbootstrapper.exe**.</li><li>The latest Teams 64-bit MSIX file from appropriate Air-Gapped download sites and upload it to the storage blob container as **MSTeams-x64.msix**.</li></ul></ol> |
| Teams | Yes | Yes | <ol><li>On a system with access to the public Internet:</br><ul><li>Download the latest [WebView2 Runtime](https://go.microsoft.com/fwlink/?linkid=2124703) and save it as **WebView2.exe**.</li><li>Download the lastest [Visual Studio Redistributables](https://aka.ms/vs/17/release/vc_redist.x64.exe) and save it as **vc_redist.x64.exe**.</li><li>Download the latest [Remote Desktop Web RTC Service installer](https://aka.ms/msrdcwebrtcsvc/msi) and save it as **MsRdcWebRTCSvc.msi**.</li></ul><li>Transfer all three files to the air-gapped network and upload them to the storage account blob container.</li><li>Ensure that the image build virtual machine can access The latest Teams Bootstrapper and the latest Teams 64-bit MSIX file from appropriate air-gapped cloud Microsoft Teams download site. |
| Teams | No | Yes | Ensure that the image build virtual machine can access The latest Teams Bootstrapper and MSIX file downloads available on the Air-Gapped network. **Note:**<span style="color:red">Teams media optimizations will not be enabled in this scenario.</span> |
| Teams | No | No | <span style="color:red">Not supported</span> |
| VDOT | Yes | Yes / No | <ol><li>On a system with access to the public Internet, download the latest [VDOT](https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool/archive/refs/heads/main.zip) and save it as **VDOT.zip**.</li><li>Transfer it to an air-gapped system and upload it to the storage account container. |

## References

### Azure Government Secret

[Azure Government Secret vs. global Azure](https://review.learn.microsoft.com/en-us/microsoft-government-secret/azure/azure-government-secret/overview/azure-government-secret-differences-from-global-azure?branch=live)

### Azure Government Top Secret

[Azure Government Top Secret vs. global Azure](https://review.learn.microsoft.com/en-us/microsoft-government-topsecret/azure/azure-government-top-secret/overview/azure-government-top-secret-differences-from-global-azure?branch=live)
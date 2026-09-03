# Image Build PowerShell Scripts

This directory contains scripts owned by the Image Build solution. Image Build Bicep modules embed
these files with `loadTextContent()` and execute them on either the image VM or the orchestration VM
through Azure VM Run Command. Shared scripts remain under
[deployments/shared/scripts](../../shared/scripts/README.md).

## Image Customization

### [Install-FSLogix.ps1](Install-FSLogix.ps1)

Installs FSLogix Apps from the configured Microsoft or artifact-storage source.

- **Parameters:** `APIVersion`, `BlobStorageSuffix`, `BuildDir`,
  `UserAssignedIdentityClientId`, `Uri`
- **Output:** `C:\Windows\Logs\Install-FSLogix.log`

### [Install-M365Applications.ps1](Install-M365Applications.ps1)

Builds an Office Deployment Tool configuration and installs the selected Microsoft 365 Apps.

- **Parameters:** `APIVersion`, `AppsToInstall`, `BlobStorageSuffix`, `BuildDir`, `Environment`,
  `Uri`, `UserAssignedIdentityClientId`
- **Behavior:** Supports cloud-specific Office configuration and explicit inclusion or exclusion of
  Access, Excel, OneNote, Outlook variants, PowerPoint, Project, Publisher, Skype for Business,
  Visio, and Word.
- **Output:** `C:\Windows\Logs\Install-Microsoft-365-Applications.log`

### [Install-OneDrive.ps1](Install-OneDrive.ps1)

Installs OneDrive per-machine for all users and configures machine-wide startup.

- **Parameters:** `APIVersion`, `BlobStorageSuffix`, `BuildDir`,
  `UserAssignedIdentityClientId`, `Uri`
- **Output:** `C:\Windows\Logs\Install-OneDrive.log`

OneDrive installation does not configure Known Folder Move. See the
[OneDrive, FSLogix, and Storage Sense guidance](../../../docs/image-build.md#onedrive-fslogix-and-storage-sense).

### [Install-Teams.ps1](Install-Teams.ps1)

Installs the new Microsoft Teams client and AVD media optimization components.

- **Parameters:** `APIVersion`, `BlobStorageSuffix`, `BuildDir`,
  `UserAssignedIdentityClientId`, `TeamsCloudType`, `Uris`, `DestFileNames`
- **Behavior:** Supports Commercial, government, air-gapped, and Gallatin Teams cloud variants.
- **Output:** `C:\Windows\Logs\Install-Teams.log`

### [Remove-AppXPackages.ps1](Remove-AppXPackages.ps1)

Removes selected installed and provisioned AppX packages from the image.

- **Parameters:** `AppsToRemove`, supplied as a JSON array
- **Output:** `C:\Windows\Logs\Remove-Apps.log`

### [Invoke-WindowsUpdate.ps1](Invoke-WindowsUpdate.ps1)

Installs Windows or Microsoft updates before image capture.

- **Parameters:** `AppName`, `Criteria`, `ExcludePreviewUpdates`, `Service`, `WSUSServer`
- **Behavior:** Supports Microsoft Update, Windows Update, and WSUS; can exclude preview updates and
  reports update and reboot results.

### [Optimize-AVDImage.ps1](Optimize-AVDImage.ps1)

Applies profile-aware VDI optimizations without an LGPO.exe or internet dependency. The script
writes ADMX-backed settings directly to Registry.pol, configures the default user profile, and
optimizes services, tasks, autologgers, network settings, and optional Windows features.

- **Parameters:** `OptimizationProfile`, `AirGapped`
- **Output:** `C:\Windows\Logs\Optimize-AVDImage.log`

#### Optimization Profiles

| Value | Behavior |
| --- | --- |
| `None` | Applies no general optimization. `AirGapped` still operates independently. |
| `NonPersistent-UpdatesOnly` | Locks down OS, M365, Teams, OneDrive, Edge, WebView2, and Store update channels. |
| `NonPersistent-Full` | Applies full pooled-host optimization plus update-channel lockdown. |
| `Persistent` | Applies full optimization while retaining update channels for Intune, Configuration Manager, or similar management. |

#### Air-Gapped Mode

`AirGapped` disables components that otherwise make unsuccessful calls to Microsoft cloud services,
including SmartScreen cloud lookups, online font providers, Teredo, WER uploads, Defender cloud
protection, OneSettings, settings sync, activity-history uploads, widgets, and cross-device
features. It applies independently of the selected optimization profile.

#### Storage Sense, Files On-Demand, and FSLogix

Full optimization profiles intentionally enable Storage Sense even though the Microsoft VDI article
generally recommends disabling it on Windows Enterprise multi-session.

| Policy | `NonPersistent-Full` | `Persistent` | Effect |
| --- | --- | --- | --- |
| Allow Storage Sense | Enabled | Enabled | Enables automatic user-content cleanup. |
| Cadence | Daily (`1`) | Monthly (`30`) | Runs cleanup more often on pooled hosts. |
| Temporary files | Enabled | Enabled | Removes eligible temporary files that aren't in use. |
| Recycle Bin | 30 days | 30 days | Permanently removes older Recycle Bin content. |
| Downloads | Never (`0`) | Never (`0`) | Doesn't delete content from Downloads. |
| Cloud dehydration | 30 days | 30 days | Returns eligible unopened cloud-backed files to online-only state. |

When the OneDrive sync root is under `%UserProfile%`, placeholders, metadata, cache, and hydrated
content occupy FSLogix container space. Files On-Demand limits hydration and Storage Sense creates
reclaimable free space by dehydrating eligible content. Neither action shrinks the physical VHDX.
FSLogix can reclaim that space and reduce the physical size of the VHDX during sign-out compaction
when its thresholds are met.

The script therefore sets Optimize Drives (`defragsvc`) to Manual on nonpersistent profiles rather
than disabling it. Scheduled OS-disk defragmentation remains disabled, while FSLogix can use the
service to determine the minimum supported VHDX size. Compaction also requires a dynamically
expanding container.

#### Deliberate Deviations from Microsoft VDI Guidance

| Item | General guidance | Image Build behavior | Reason |
| --- | --- | --- | --- |
| Storage Sense | Disable | Enable and configure | Dehydrates eligible cloud content and cleans temporary profile content before FSLogix compaction. |
| Optimize Drives | Evaluate or disable | Manual on nonpersistent hosts | Disabled service startup prevents FSLogix VHD disk compaction. |
| Windows Search | Evaluate or disable | Leave at default | Disabling it breaks Outlook and File Explorer search. |
| Microsoft Store Install Service | Disable on nonpersistent hosts | Leave at default | WinAppSDK applications can require the on-demand service at first launch. |
| Sync Host (`OneSyncSvc`) | Candidate for disabling | Leave at default | Mail, contacts, and calendar applications depend on synchronization at sign-in. |
| Diagnostic services | Disable | Disable only on nonpersistent hosts | Persistent users retain self-service diagnostic capabilities. |
| Registry backup and silent cleanup tasks | Disable | Retain | They provide registry recovery and low-space cleanup value. |
| OneDrive pre-sign-in traffic restriction | Enable | Don't configure | It prevents the intended silent OneDrive account and KFM experience. |

Microsoft recommends evaluating every optimization against application, security, servicing, and
user-experience requirements. See the
[Microsoft VDI optimization guide](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remote-desktop-services-vdi-optimize-configuration)
and the [FederalAVD Image Build guide](../../../docs/image-build.md#vdi-optimization).

### [Invoke-DiskCleanup.ps1](Invoke-DiskCleanup.ps1)

Removes image-build staging content and transient operating-system data before capture.

- **Parameters:** `BuildDir`
- **Behavior:** Cleans temporary folders, selected Windows logs and caches, WER data, BranchCache,
  Delivery Optimization cache, Recycle Bin content, and event logs.
- **Output:** `C:\Windows\Logs\Invoke-DiskCleanup.log`

### [Get-ImageManifest.ps1](Get-ImageManifest.ps1)

Records the operating-system version, installed applications, and Windows hotfixes for the completed
image.

- **Parameters:** None
- **Output:** `C:\Windows\Logs\Image-Manifest.log`, also captured with customization logs when
  configured

## Restart and Servicing Control

### [Check-CbsState.ps1](Check-CbsState.ps1)

Checks Component Based Servicing state and active servicing processes before restart or capture.

- **Behavior:** Waits for TiWorker and TrustedInstaller, checks the relevant reboot registry keys,
  and emits `RESTART_REQUIRED=true` or `RESTART_REQUIRED=false` as the first output line.
- **Output:** `C:\Windows\Logs\Check-CbsState-<timestamp>.log` and Run Command output

### [Invoke-ConditionalRestart.ps1](Invoke-ConditionalRestart.ps1)

Runs on the orchestration VM and restarts the image VM only when `Check-CbsState.ps1` reports a
pending restart.

- **Parameters:** `ResourceManagerUri`, `UserAssignedIdentityClientId`, `ImageVmResourceId`,
  `RunCommandName`
- **Behavior:** Reads Run Command instance view, invokes the Azure restart API, and follows the
  long-running operation to completion.

### [Restart-Vm.ps1](Restart-Vm.ps1)

Restarts the image VM after a customization that requests a reboot.

- **Parameters:** `ResourceManagerUri`, `UserAssignedIdentityClientId`, `VmResourceId`
- **Behavior:** Uses Azure REST with managed identity and waits for the VM to return to running state.

### [Resize-Disk.ps1](Resize-Disk.ps1)

Extends the image VM's operating-system partition to consume the available managed-disk space.

- **Parameters:** None
- **Behavior:** Refreshes the host storage cache and uses DiskPart to extend the current system
  partition. An already maximized partition is treated as success.

## Image Finalization and Capture

### [Invoke-Sysprep.ps1](Invoke-Sysprep.ps1)

Runs Sysprep under the named built-in administrator rather than SYSTEM and captures Panther logs.

- **Parameters:** `AdminPassword`
- **Behavior:** Waits for required services and CBS servicing, prepares the administrator profile,
  launches Sysprep with `/oobe /generalize /quit /mode:vm`, checks the exit code, and emits Panther
  logs to Run Command output.
- **Output:** Sysprep Panther logs in the Run Command output blob

### [Generalize-Vm.ps1](Generalize-Vm.ps1)

Deallocates the Sysprep-completed image VM and marks it generalized through Azure REST.

- **Parameters:** `ResourceManagerUri`, `UserAssignedIdentityClientId`, `VmResourceId`
- **Behavior:** Deallocates the VM, waits for `VM deallocated`, then invokes the generalize action.

### [Remove-ImageBuildRunCommands.ps1](Remove-ImageBuildRunCommands.ps1)

Removes Run Command resources from the image VM between customization batches and before capture.

- **Parameters:** `ResourceManagerUri`, `SubscriptionId`, `UserAssignedIdentityClientId`,
  `ImageVmName`, `ImageVmResourceGroup`
- **Behavior:** Deletes all image VM Run Commands and waits up to ten minutes for their removal.

### [Remove-ImageBuildResources.ps1](Remove-ImageBuildResources.ps1)

Removes temporary image-build resources after the image version has been captured.

- **Parameters:** `ResourceManagerUri`, `UserAssignedIdentityClientId`, `ImageVmResourceId`,
  `ManagementVmResourceId`, `ImageResourceId`, `ResourceGroupId`
- **Behavior:** Deletes build VMs and supporting resources while preserving the captured image
  resource and respecting whether the deployment created or reused the resource group.

## Conventions

- These scripts are implementation details of Image Build and aren't general operator utilities.
- Azure REST and private artifact-storage access use managed identity.
- Every PowerShell file must remain ASCII-only because Bicep embeds it in generated ARM JSON.
- Image Build logs can be collected in the configured log storage account; see
  [Image Build logging](../README.md#logging).

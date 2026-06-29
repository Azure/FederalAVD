# Common PowerShell Scripts

This directory contains reusable PowerShell scripts used by both the image management and host pool deployment solutions. These scripts are loaded dynamically into Bicep templates using `loadTextContent()` and executed via Azure Run Command or Custom Script Extension.

## Script Categories

### 📦 Application Installation

#### [Install-FSLogix.ps1](Install-FSLogix.ps1)

Installs FSLogix agent from Microsoft or custom location.

- **Used by:** Image Management
- **Parameters:** APIVersion, BlobStorageSuffix, BuildDir, UserAssignedIdentityClientId, Uri
- **Output:** Installation log at `C:\Windows\Logs\Install-FSLogix.log`

#### [Install-M365Applications.ps1](Install-M365Applications.ps1)

Installs Microsoft 365 Applications (formerly Office 365) with customizable application selection.

- **Used by:** Image Management
- **Parameters:** APIVersion, AppsToInstall, BlobStorageSuffix, BuildDir, Environment, Uri, UserAssignedIdentityClientId
- **Features:** Supports custom configuration XML for selecting specific Office apps
- **Output:** Installation log at `C:\Windows\Logs\Install-Microsoft-365-Applications.log`

#### [Install-OneDrive.ps1](Install-OneDrive.ps1)

Installs OneDrive per-machine (all users) for AVD optimization.

- **Used by:** Image Management
- **Parameters:** APIVersion, BlobStorageSuffix, BuildDir, Uri, UserAssignedIdentityClientId
- **Output:** Installation log at `C:\Windows\Logs\Install-OneDrive.log`

#### [Install-Teams.ps1](Install-Teams.ps1)

Installs Microsoft Teams optimized for Azure Virtual Desktop.

- **Used by:** Image Management
- **Parameters:** APIVersion, BlobStorageSuffix, BuildDir, UserAssignedIdentityClientId, TeamsCloudType, Uris, DestFileNames
- **Features:** Supports multi-cloud environments, WebRTC redirector, and Teams machine-wide installer
- **Output:** Installation log at `C:\Windows\Logs\Install-Teams.log`

### ⚙️ System Configuration

#### [Initialize-SessionHost.ps1](Initialize-SessionHost.ps1)

Unified session host initialization script that combines configuration and AVD agent installation into a single Run Command execution. This is the primary script executed on each session host after VM provisioning.

- **Used by:** Host Pool Deployment
- **Log:** `C:\Windows\Logs\Initialize-SessionHost.log`

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `RegistrationToken` | Yes | Host pool registration token for joining the session host |
| `AgentBootLoaderUrl` | Yes | Direct URL to download the RDAgentBootLoader MSI |
| `TimeZone` | Yes | Windows time zone ID to configure (e.g. `Eastern Standard Time`) |
| `AgentUrl` | No | Direct URL to the RDAgent MSI — used if the Azure broker endpoint is unreachable |
| `AADJoin` | No | `'true'` if the VM is Entra ID (Azure AD) joined; default `'false'` |
| `MdmId` | No | MDM enrollment ID for Intune auto-enrollment with Entra ID join |
| `UserAssignedIdentityClientId` | No | Client ID of a managed identity for authenticating to Azure Storage |
| `ApiVersion` | No | Azure IMDS API version for token requests |
| `StorageSuffix` | No | Cloud-specific blob storage DNS suffix (e.g. `core.windows.net`) |
| `AmdVmSize` | No | `'true'` to enable AMD GPU optimizations; default `'false'` |
| `NvidiaVmSize` | No | `'true'` to enable NVIDIA GPU optimizations; default `'false'` |
| `DisableUpdates` | No | `'true'` to disable Windows, Edge, OneDrive, M365, and Teams auto-updates; default `'false'` |
| `ConfigureFSLogix` | No | `'true'` to configure FSLogix profile containers; default `'false'` |
| `CloudCache` | No | `'true'` to enable FSLogix Cloud Cache; default `'false'` |
| `IdentitySolution` | No | One of: `ActiveDirectoryDomainServices`, `EntraDomainServices`, `EntraKerberos-Hybrid`, `EntraKerberos-CloudOnly`, `EntraId` |
| `StorageService` | No | `AzureFiles` or `AzureNetAppFiles` |
| `Shares` | No | JSON array of file share names — index 0 = profile share, index 1 = ODFC share |
| `SizeInMBs` | No | FSLogix container size in MB; default `30000` |
| `LocalStorageAccountNames` | No | JSON array of local storage account names |
| `LocalStorageAccountKeys` | No | JSON array of local storage account keys (stored in Credential Manager) |
| `LocalNetAppServers` | No | JSON array of local NetApp server FQDNs |
| `OSSGroups` | No | JSON array of AD groups for FSLogix Object Specific Settings |
| `RemoteStorageAccountNames` | No | JSON array of remote (DR) storage account names |
| `RemoteStorageAccountKeys` | No | JSON array of remote storage account keys |
| `RemoteNetAppServers` | No | JSON array of remote NetApp server FQDNs |

**Execution Phases:**

*Phase 1 — Session Host Configuration*
- Sets the system time zone
- Optionally disables Windows Update, Edge, OneDrive, M365, and Teams auto-updates
- Enables time zone redirection registry policy
- Configures AMD/NVIDIA GPU registry settings when applicable
- Configures FSLogix profile and ODFC containers (VHDLocations or CCDLocations), including:
  - Azure Files and Azure NetApp Files storage paths
  - Object Specific Settings (per-group VHD locations)
  - Cloud Cache support
  - FSLogix Redirections XML for Teams and Azure CLI profile exclusions
  - Entra Kerberos `CloudKerberosTicketRetrievalEnabled` registry value
  - Windows Defender path and process exclusions for FSLogix
  - Local administrator added to FSLogix exclude lists
- Applies all registry settings via `Set-RegistryValue`
- Resizes the OS disk partition to its maximum supported size

*Phase 2 — AVD Agent Installation*
- Detects Server OS and installs `RDS-RD-Server` Windows Feature if needed
- Skips installation if the VM is already registered (`RDInfraAgent` registry key)
- Downloads the RDAgent MSI using a two-tier strategy:
  1. Queries the AVD broker endpoint via the registration token JWT
  2. Falls back to the explicit `AgentUrl` parameter
- Downloads the RDAgentBootLoader MSI from `AgentBootLoaderUrl`
- Installs RDAgentBootLoader and RDAgent via MSI with automatic retry on `ERROR_INSTALL_ALREADY_RUNNING` (exit code 1618)
- Waits for the `RDAgentBootLoader` service to start
- Cleans up the temporary download folder

#### [Set-SessionHostConfiguration.ps1](Set-SessionHostConfiguration.ps1)

Comprehensive session host configuration including FSLogix, GPU drivers, time zone, and optional Windows Update disabling.

- **Used by:** Host Pool Deployment
- **Parameters:** AmdVmSize, NvidiaVmSize, DisableUpdates, ConfigureFSLogix, CloudCache, IdentitySolution, LocalNetAppServers, LocalStorageAccountNames, LocalStorageAccountKeys, OSSGroups, RemoteNetAppServers, RemoteStorageAccountNames, RemoteStorageAccountKeys, Shares, SizeInMBs, StorageAccountDNSSuffix, StorageService, TimeZone
- **Features:** 
  - FSLogix profile container configuration with Cloud Cache support
  - GPU driver installation (AMD/NVIDIA)
  - Time zone configuration
  - Windows Update management
  - Storage account configuration for profiles
- **Output:** Session host configuration logs

#### [Set-FSLogixSessionHostConfiguration.ps1](Set-FSLogixSessionHostConfiguration.ps1)

Dedicated FSLogix configuration for session hosts.
- **Used by:** Host Pool Deployment
- **Purpose:** Configure FSLogix registry settings for profile and ODFC containers

#### [Set-ConfidentialVMOSDiskEncryptionKey.ps1](Set-ConfidentialVMOSDiskEncryptionKey.ps1)

Configures OS disk encryption keys for confidential VMs.

- **Used by:** Host Pool Deployment
- **Purpose:** Secure boot and encryption key management for confidential compute

#### [Disable-PrivacyExperience.ps1](Disable-PrivacyExperience.ps1)

Disables Windows privacy experience prompts for AVD multi-user scenarios.

- **Used by:** Image Management
- **Purpose:** Suppress privacy setup screens on first logon
- **Features:** Configures registry keys to skip OOBE privacy screens

#### [Enable-RDPShortPathListener.ps1](Enable-RDPShortPathListener.ps1)

Configures RDP Shortpath for direct UDP transport.

- **Used by:** Image Management, Host Pool Deployment
- **Purpose:** Enable low-latency RDP connections via UDP
- **Features:** 
  - Creates registry keys for UDP port redirector
  - Configures firewall rules for port 3390
- **Reference:** [RDP Shortpath Documentation](https://docs.microsoft.com/en-us/azure/virtual-desktop/shortpath)

### 🗄️ Storage Configuration

#### [Configure-StorageAccountforADDS.ps1](Configure-StorageAccountforADDS.ps1)

Configures Azure Files storage account for Active Directory Domain Services authentication.

- **Used by:** Host Pool Deployment
- **Parameters:** DomainJoinUserPwd, DomainJoinUserPrincipalName, HostPoolName, KerberosEncryptionType, OuPath, ResourceManagerUri, StorageAccountPrefix, StorageAccountResourceGroupName, StorageCount
- **Features:** 
  - Domain join storage account computer objects
  - Configure Kerberos encryption (AES256/RC4)
  - Set SPNs for file share access
- **Output:** AD DS integration for FSLogix profile storage

#### [Configure-StorageAccountforEntraHybrid.ps1](Configure-StorageAccountforEntraHybrid.ps1)

Configures Azure Files storage account for Entra ID Kerberos authentication (hybrid scenarios).

- **Used by:** Host Pool Deployment
- **Purpose:** Enable Entra ID Kerberos authentication for FSLogix storage
- **Features:** Supports hybrid identity scenarios with on-premises AD sync

#### [Set-NtfsPermissionsAzureFiles.ps1](Set-NtfsPermissionsAzureFiles.ps1)

Sets NTFS permissions on Azure Files shares for FSLogix profiles.

- **Used by:** Host Pool Deployment
- **Parameters:** Shares, ShardAzureFilesStorage, StorageAccountPrefix, StorageCount, StorageIndex, StorageSuffix, UserAssignedIdentityClientId, UserGroups
- **Features:** 
  - Configure share-level and NTFS permissions
  - Support for user/group-based access control
  - Entra ID SID conversion for cloud-only identities
- **Output:** Properly secured FSLogix profile shares

#### [Set-NtfsPermissionsNetApp.ps1](Set-NtfsPermissionsNetApp.ps1)

Sets NTFS permissions on Azure NetApp Files volumes for FSLogix profiles.

- **Used by:** Host Pool Deployment
- **Purpose:** Configure NTFS ACLs for ANF-based profile storage
- **Features:** Similar to Azure Files but optimized for NetApp storage

#### [Update-StorageAccountApplications.ps1](Update-StorageAccountApplications.ps1)

Updates Entra ID Kerberos application registrations for storage accounts.

- **Used by:** Host Pool Deployment
- **Purpose:** Maintain Entra ID app registrations for Kerberos authentication
- **Features:** Automate application credential rotation and updates

### 🔄 Customization & Updates

#### [Invoke-Customization.ps1](Invoke-Customization.ps1)

**[Shared Script]** - Executes custom scripts or commands from URLs or blob storage during deployment.

- **Used by:** Image Management, Host Pool Deployment
- **Parameters:** APIVersion, Arguments, BlobStorageSuffix, BuildDir, Name, Uri, UserAssignedIdentityClientId
- **Features:**
  - Execute scripts from public URLs or private blob storage
  - Support for PowerShell scripts (.ps1) and executables (.exe)
  - Automatic argument parsing and handling
  - Managed identity authentication for private storage
- **Output:** Execution logs with timestamps

#### [Invoke-WindowsUpdate.ps1](Invoke-WindowsUpdate.ps1)

Runs Windows Update during image build process.

- **Used by:** Image Management
- **Parameters:** AppName, Criteria, ExcludePreviewUpdates, Service, WSUSServer
- **Features:**
  - Support for Windows Update, Microsoft Update, WSUS
  - Exclude preview/optional updates
  - Installation result reporting
- **Output:** Update installation logs and reboot management

#### [Optimize-AVDImage.ps1](Optimize-AVDImage.ps1)

Applies VDI performance and resource optimizations to a Windows image for AVD deployment. Writes
Group Policy settings directly to `Registry.pol` in MS-GPREG (PReg) binary format — no LGPO.exe
or internet access required. Configures default user profile settings, disables unnecessary services,
scheduled tasks, autologgers, and optional Windows features.

- **Used by:** Image Management
- **Parameters:** `OptimizationProfile`, `AirGapped`
- **Output:** `C:\Windows\Logs\Optimize-AVDImage.log`

##### Optimization Profiles (`-OptimizationProfile`)

| Value | Behavior |
|---|---|
| `None` | No optimization. Only `-AirGapped` takes effect when `None`. |
| `NonPersistent-UpdatesOnly` | Locks down all software update channels only (Sections 2, 4, 6): OS, M365, Teams, OneDrive, Edge, WebView2, Store. |
| `NonPersistent-Full` | Full optimization for pooled AVD host pools replaced on a regular cadence. |
| `Persistent` | Full optimization minus update-channel lockdown. Update channels remain intact for SCCM/Intune. |

##### Air-Gapped Mode (`-AirGapped`)

When `true`, applies additional settings for environments with no outbound internet access (Section 7):

| Setting | ADMX source | Rationale |
|---|---|---|
| **SmartScreen** disabled (Explorer + Edge) | `SmartScreen.admx` | Cloud lookups time out, causing 10–30 s delays on every exe launch and URL navigation |
| **Online font providers** disabled | `ICM.admx` | Prevents outbound calls to Microsoft font CDN |
| **Teredo IPv6** disabled | `TCPIP.admx` | No internet-facing IPv6 tunnel needed in VDI |
| **Defender cloud protection** (MAPS/BAFS) disabled | `WindowsDefender.admx` | Cloud lookups time out; SpynetReporting=0, SubmitSamplesConsent=2, DisableBlockAtFirstSeen=1 |
| **Windows Error Reporting** policy disabled | `WindowsErrorReporting.admx` | Watson upload attempts time out in restricted networks (WerSvc also disabled for NonPersistent in Section 2) |
| **DiagTrack** service disabled | — | Continuous telemetry upload attempts fail (already disabled for NonPersistent in Section 2; this covers Persistent+AirGapped) |
| **OneSettings downloads** disabled | `DataCollection.admx` | Prevents DiagTrack from pulling dynamic telemetry config from Microsoft |
| **Cross-device clipboard** disabled | `OSPolicy.admx` | Stops clipboard sync to Microsoft cloud |
| **News and Interests / Widgets** disabled | `NewsAndInterests.admx` | Stops widget panel polling Microsoft news endpoints |
| **Settings sync** disabled | `SettingSync.admx` | Stops cloud sync of Windows settings; competes with FSLogix as a second source of truth for profile state |
| **Activity history upload** disabled | `OSPolicy.admx` | Stops upload to `activity.windows.com`; local feed (recent files, Jump Lists via FSLogix) is preserved |

Applies independently of `-OptimizationProfile`, including when profile is `None`.

##### Policy Registry Audit (W11 25H2)

All policy paths and value names are ADMX-backed, verified against `C:\Windows\PolicyDefinitions`
on Windows 11 25H2. Settings appear under **Administrative Templates** in `gpresult` output rather
than Extra Registry Settings. `gpupdate` is intentionally **not** called during image build — the
build VM is about to be sysprepped. Policies take effect on deployed session hosts at first boot.

**Exception:** `NetworkList\Signatures\EveryNetwork\CategoryReadOnly` has no ADMX backing by
design (it is a Security Settings value) and is written via direct registry.

##### Deliberate Deviations from the Microsoft VDI Optimization Article

| Item | Article Recommendation | What This Script Does | Reason |
|---|---|---|---|
| **Storage Sense** | Disable | Enable and configure | FSLogix + OneDrive Files On-Demand caches files in the profile container. Without dehydration the container grows monotonically. Storage Sense is configured to dehydrate cloud content not opened in 30 days and clean temp files. |
| **WSearch** | Evaluate / disable | Leave at default (Manual) | Disabling breaks Outlook and File Explorer search for all users for the entire VM lifetime. The OS search index persists across the VM's full lifecycle and the FSLogix Outlook search index lives in the profile container. |
| **InstallService** | Disable on NonPersistent | Leave at default (Manual) | Disabling causes WinAppSDK-based apps (Sticky Notes, Snipping Tool) to show a "needs an update" error at first launch, including on air-gapped networks. |
| **OneSyncSvc** | Not listed / candidate | Leave at default | Re-syncs Exchange mail, contacts, and calendar at session start. UWP app data is excluded from FSLogix containers so there is no cached state to fall back on — disabling leaves Mail and Calendar empty. |
| **DPS / DiagSvc / WdiSystemHost** | Disable | NonPersistent only | On Persistent VMs these back the end-user Troubleshoot/Diagnose UX in Settings. Disabling on long-lived desktops breaks self-service diagnostics. |
| **RegIdleBackup / SilentCleanup** | Disable | Retain | Registry hive backups enable mid-lifecycle corruption recovery. SilentCleanup only triggers on low disk space — both have operational value across the VM's monthly lifetime. |

#### [Check-CbsState.ps1](Check-CbsState.ps1)

Checks Component Based Servicing (CBS) registry state on the image VM to determine if a restart is required before proceeding with customization or sysprep.

- **Used by:** Image Management (via `conditionalRestart.bicep` module)
- **Features:**
  - Waits up to 10 minutes for TiWorker.exe and TrustedInstaller.exe to exit before reading registry
  - Checks `RebootPending`, `RebootInProgress`, `RebootRequired`, and `SessionsPending\Exclusive` keys
  - Emits `RESTART_REQUIRED=true` or `RESTART_REQUIRED=false` as the first stdout line (instanceView-safe signal)
  - Full timestamped log follows the signal in stdout and is written to `C:\Windows\Logs\Check-CbsState-*.log`
- **Output:** Signal line first in stdout, full log at `C:\Windows\Logs\Check-CbsState-*.log`

#### [Invoke-ConditionalRestart.ps1](Invoke-ConditionalRestart.ps1)

Runs on the orchestration VM. Reads the `instanceView.output` of the `Check-CbsState` run command via ARM REST API and, if `RESTART_REQUIRED=true`, calls the ARM restart API (synchronous LRO) then waits 60 seconds for the guest agent to initialize.

- **Used by:** Image Management (via `conditionalRestart.bicep` module)
- **Parameters:** ResourceManagerUri, UserAssignedIdentityClientId, ImageVmResourceId, RunCommandName
- **Features:**
  - Reads run command instanceView without needing a separate deploymentScript resource
  - Uses ARM restart LRO (definitive completion signal) instead of polling power state
  - No timing races — restart only occurs when the CBS check script has already confirmed the need
- **Output:** Restart decision and polling progress written to stdout (captured in blob log)

#### [Invoke-Sysprep.ps1](Invoke-Sysprep.ps1)

Executes sysprep to generalize Windows images, then captures the Panther logs into the Run Command output blob.

- **Used by:** Image Management
- **Parameters:** AdminUserPw
- **Features:**
  - Waits for required services (RdAgent, WindowsAzureGuestAgent) to be running
  - Removes cached unattend files that would interfere with OOBE
  - Enables the built-in local administrator account (required by the scheduled task)
  - Waits for CBS (Component Based Servicing) to settle; exits with an error if a reboot is still pending
  - Registers a scheduled task to run sysprep `/oobe /generalize /quit /mode:vm` under the local admin account
  - Starts the task immediately with `Start-ScheduledTask` and confirms it enters **Running** state within 2 minutes — fails fast if sysprep never launches
  - Waits up to 30 minutes for sysprep to complete, then checks the scheduled task exit code
  - Emits `setupact.log` and `setuperr.log` from `C:\Windows\System32\Sysprep\Panther\` to stdout so they are captured by the Run Command `outputBlobUri`
  - Fails the Run Command (and the deployment) if sysprep returns a non-zero exit code, with the Panther log already in the output blob
  - Deregisters the scheduled task on success
  - Exits cleanly — `Generalize-Vm.ps1` handles deallocate and generalize
- **Output:** Panther logs in the Run Command output blob; VM left running and generalized (ready for deallocate)

### 🧹 Cleanup & Removal

#### [Remove-AppXPackages.ps1](Remove-AppXPackages.ps1)

Removes built-in Windows AppX packages during image build.

- **Used by:** Image Management
- **Parameters:** AppsToRemove (JSON array)
- **Features:**
  - Removes both provisioned and installed AppX packages
  - Supports bulk removal for image optimization
- **Output:** Log at `C:\Windows\Logs\Remove-Apps.log`

#### [Remove-RunCommands.ps1](Remove-RunCommands.ps1)

**[Shared Script]** - Cleans up Azure Run Commands after execution.

- **Used by:** Image Management, Host Pool Deployment
- **Parameters:** ResourceManagerUri, SubscriptionId, UserAssignedIdentityClientId, VirtualMachineNames, VirtualMachinesResourceGroup
- **Features:**
  - Uses managed identity authentication
  - Removes all Run Commands from specified VMs
  - Supports multi-cloud environments
- **Purpose:** Clean up deployment artifacts and sensitive command data

#### [Remove-CustomScriptExtension.ps1](Remove-CustomScriptExtension.ps1)

Removes Custom Script Extension from VMs.

- **Used by:** Image Management
- **Purpose:** Clean up CSE artifacts before image capture

#### [Remove-ImageBuildResources.ps1](Remove-ImageBuildResources.ps1)

Deletes temporary image build resources after successful image capture.

- **Used by:** Image Management
- **Purpose:** Clean up build VM, disks, NICs, and other temporary resources
- **Features:** Uses managed identity to delete resource group containing build artifacts

#### [Remove-ResourceGroup.ps1](Remove-ResourceGroup.ps1)

Deletes Azure resource groups.

- **Used by:** Host Pool Deployment
- **Purpose:** Clean up deployment resource groups during teardown operations

#### [Remove-RoleAssignments.ps1](Remove-RoleAssignments.ps1)

Removes Azure RBAC role assignments.

- **Used by:** Host Pool Deployment
- **Purpose:** Clean up temporary role assignments created during deployment

### 🔧 Virtual Machine Operations

#### [Generalize-Vm.ps1](Generalize-Vm.ps1)

Deallocates a running generalized VM and marks it as generalized via the Azure REST API.

- **Used by:** Image Management
- **Parameters:** ResourceManagerUri, UserAssignedIdentityClientId, VmResourceId
- **Features:**
  - Uses managed identity authentication (UAI or system-assigned)
  - Calls `/deallocate` directly on the running VM — no prior stop required; Azure handles the stop+deallocate in one operation
  - Polls VM power state until `VM deallocated` (5-minute timeout)
  - Calls `/generalize` to mark the VM for image capture
- **Purpose:** Prepare VM for Azure Compute Gallery image creation after `Invoke-Sysprep.ps1` has completed

#### [Restart-Vm.ps1](Restart-Vm.ps1)

Restarts an Azure VM via REST API and waits for it to be running.

- **Used by:** Image Management
- **Parameters:** ResourceManagerUri, UserAssignedIdentityClientId, VmResourceId
- **Features:**
  - Uses managed identity authentication
  - Polls VM status until running
  - Supports multi-cloud environments
- **Purpose:** Reboot VMs after software installation or configuration changes

#### [Update-AvdSessionDesktopName.ps1](Update-AvdSessionDesktopName.ps1)

Updates the friendly name of the AVD session desktop in an application group.

- **Used by:** Host Pool Deployment
- **Parameters:** ApplicationGroupResourceId, FriendlyName, ResourceManagerUri, UserAssignedIdentityClientId
- **Purpose:** Customize desktop display name for better user experience

#### [Update-ImageCaptureSource.ps1](Update-ImageCaptureSource.ps1)

Updates image capture source references.

- **Used by:** Image Management
- **Purpose:** Maintain image versioning and source tracking

#### [Set-AvdDrainMode.ps1](Set-AvdDrainMode.ps1)

Sets or removes drain mode on AVD session hosts.

- **Used by:** Host Pool Deployment
- **Purpose:** Gracefully prepare session hosts for maintenance or removal
- **Features:** Prevents new sessions while allowing existing sessions to complete

#### [Get-RoleAssignments.ps1](Get-RoleAssignments.ps1)

Retrieves Azure RBAC role assignments for auditing.

- **Used by:** Host Pool Deployment
- **Purpose:** Audit and document role assignments created during deployment

## Usage Patterns

### Script Execution Methods

1. **Azure Run Command** (Most Common)
   - Scripts executed via Run Command API
   - Supports managed identity authentication
   - Automatic cleanup with `Remove-RunCommands.ps1`

2. **Custom Script Extension**
   - Scripts downloaded and executed via CSE
   - Used for initial VM configuration
   - Removed before image capture with `Remove-CustomScriptExtension.ps1`

3. **Direct Execution**
   - Some scripts run locally within VMs during customization

### Common Parameter Patterns

- **UserAssignedIdentityClientId**: Used for managed identity authentication to access Azure resources
- **ResourceManagerUri**: Azure environment endpoint (varies by cloud: Azure, Azure Gov, Azure China)
- **BlobStorageSuffix**: Cloud-specific blob storage endpoint
- **APIVersion**: Azure API version for REST calls
- **BuildDir**: Optional temporary directory for downloads (defaults to `$env:TEMP`)

## Script Dependencies

### Shared Scripts (Used by Both Solutions)

- `Invoke-Customization.ps1`
- `Remove-RunCommands.ps1`

### Image Management Only

- Application installers (FSLogix, M365, OneDrive, Teams)
- Image optimization (`Optimize-AVDImage.ps1`)
- CBS state check and conditional restart (`Check-CbsState.ps1`, `Invoke-ConditionalRestart.ps1`)
- Image finalization (Sysprep, Generalize)

### Host Pool Deployment Only

- Session host configuration
- FSLogix storage configuration
- NTFS permission management
- Entra ID/AD DS integration
- AVD control plane updates

## Multi-Cloud Support

All scripts support multiple Azure clouds through parameterization:

- **Azure Commercial** (`management.azure.com`, `blob.core.windows.net`)
- **Azure Government** (`management.usgovcloudapi.net`, `blob.core.usgovcloudapi.net`)
- **Azure China** (`management.chinacloudapi.cn`, `blob.core.chinacloudapi.cn`)

Scripts use the `ResourceManagerUri` and `BlobStorageSuffix` parameters to adapt to the target cloud environment.

## Logging Standards

Most scripts follow consistent logging patterns:

- **Transcripts**: Started with `Start-Transcript` to capture all output
- **Log Location**: `C:\Windows\Logs\` directory
- **Naming Convention**: `Install-<SoftwareName>.log` or `<Action>-<Component>.log`
- **Timestamps**: Custom `Write-OutputWithTimeStamp` function for timestamped entries
- **Format**: `[MM/dd/yyyy HH:mm:ss] Message`

## Error Handling

Standard error handling approach:

```powershell
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
```

This ensures:

- Scripts fail fast on errors
- Warnings don't clutter logs
- Bicep deployments detect failures appropriately

## Security Considerations

- **Managed Identity**: Scripts use user-assigned managed identities instead of credentials
- **No Hardcoded Secrets**: All sensitive data passed as parameters or retrieved from Key Vault
- **Least Privilege**: Scripts request only necessary permissions
- **Cleanup**: Sensitive Run Commands removed after execution
- **Audit Trail**: Comprehensive logging for compliance and troubleshooting

## Maintenance

When modifying scripts:

1. Maintain parameter consistency across similar scripts
2. Update both Bicep references if changing script names
3. Test in multi-cloud environments if applicable
4. Update logging to follow standards
5. Document breaking changes in solution documentation

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

#### [Invoke-WDOT.ps1](Invoke-WDOT.ps1)

Runs Windows Desktop Optimization Tool (WDOT) for AVD image optimization.

- **Used by:** Image Management
- **Parameters:** APIVersion, BlobStorageSuffix, BuildDir, Uri, UserAssignedIdentityClientId
- **Features:** Downloads and executes WDOT to optimize Windows for virtual desktop workloads
- **Default Source:** [Virtual Desktop Team GitHub](https://github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool)
- **Output:** Optimized OS configuration for AVD

#### [Invoke-Sysprep.ps1](Invoke-Sysprep.ps1)

Executes sysprep to generalize Windows images.

- **Used by:** Image Management
- **Parameters:** APIVersion, UserAssignedIdentityClientId, LogBlobContainerUri, AdminUserPw
- **Features:**
  - Waits for required services (RdAgent, WindowsAzureGuestAgent)
  - Uploads sysprep logs to blob storage
  - Handles sysprep execution and error scenarios
- **Output:** Generalized VM ready for image capture

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

Generalizes (stops and marks as generalized) a VM via Azure REST API.

- **Used by:** Image Management
- **Parameters:** ResourceManagerUri, UserAssignedIdentityClientId, VmResourceId
- **Features:**
  - Uses managed identity authentication
  - Stops and generalizes VM for image capture
  - Validates VM state transitions
- **Purpose:** Prepare VM for Azure Compute Gallery image creation

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
- Image optimization tools (WDOT, AppX removal)
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

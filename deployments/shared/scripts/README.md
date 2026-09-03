# Shared Deployment PowerShell Scripts

This directory contains PowerShell implementation scripts reused by more than one deployment
solution or by shared orchestration modules. Bicep templates embed these scripts with
`loadTextContent()` and execute them through Azure VM Run Command.

Solution-specific scripts are documented with their owning solutions:

- [Image Build scripts](../../imageBuild/scripts/README.md)
- [Standard Host Pool scripts](../../hostpools/scripts/README.md)
- [Automated Host Pool scripts](../../automatedHostPools/scripts/README.md)
- Add-on scripts remain under their individual `deployments/add-ons/<name>/` folders.

## Session Host Provisioning

### [Initialize-SessionHost.ps1](Initialize-SessionHost.ps1)

Initializes directly managed session hosts and installs the AVD agent in one Run Command.

- **Used by:** Shared standard session-host orchestration
- **Parameters:** `ApiVersion`, `StorageSuffix`, `RegistrationToken`, `AgentBootLoaderUrl`,
  `AgentUrl`, `AADJoin`, `MdmId`, `UserAssignedIdentityClientId`, `TimeZone`, GPU flags, and
  FSLogix storage settings
- **Behavior:**
  - Configures time zone, GPU settings, FSLogix Profile and ODFC containers, Cloud Cache, Object
    Specific Settings, Defender exclusions, and Entra Kerberos policy as selected.
  - Resizes the OS partition to the available disk size.
  - Downloads and installs the AVD agent and boot loader, then waits for the service to start.
- **Output:** `C:\Windows\Logs\Initialize-SessionHost.log`

The automated host pool policy workflow uses a different, solution-owned implementation that
configures the host but does not install the AVD agent. See the
[Automated Host Pool scripts reference](../../automatedHostPools/scripts/README.md).

## Customization Execution

### [Invoke-Customization.ps1](Invoke-Customization.ps1)

Downloads and executes an artifact during image or session-host provisioning.

- **Used by:** Image Build, standard host pools, and automated host pool policy orchestration
- **Parameters:** `APIVersion`, `Arguments`, `BlobStorageSuffix`, `BuildDir`, `Name`, `Uri`,
  `UserAssignedIdentityClientId`
- **Behavior:** Downloads public or managed-identity-protected content, extracts ZIP packages,
  discovers the package entry point, converts the arguments string to typed PowerShell parameters,
  executes the customization, and reports actionable errors.
- **Output:** Customization output and logs named for the supplied customization `Name`

## FSLogix Storage Configuration

### [Configure-StorageAccountforADDS.ps1](Configure-StorageAccountforADDS.ps1)

Configures Azure Files storage accounts for Active Directory Domain Services authentication.

- **Used by:** Shared FSLogix orchestration consumed by host pools and the FSLogix Storage add-on
- **Parameters:** Domain join credentials and domain information, Kerberos encryption type,
  storage account naming and indexing values, Azure endpoint values, subscription ID, and managed
  identity client ID
- **Behavior:** Discovers an AD Web Services-capable domain controller, creates or updates storage
  account computer objects, and configures Kerberos encryption and service principal names.

### [Configure-StorageAccountforEntraHybrid.ps1](Configure-StorageAccountforEntraHybrid.ps1)

Configures Azure Files storage accounts for Microsoft Entra Kerberos hybrid authentication.

- **Used by:** Shared FSLogix orchestration consumed by host pools and the FSLogix Storage add-on
- **Parameters:** `DefaultSharePermission`, domain join credentials and domain name, storage account
  naming and indexing values, Azure endpoint values, subscription ID, and managed identity client ID
- **Behavior:** Discovers an AD Web Services-capable domain controller and configures Azure Files
  identity-based authentication with domain information.

### [Update-StorageAccountApplicationManifest.ps1](Update-StorageAccountApplicationManifest.ps1)

Updates the Microsoft Entra application objects created for Azure Files Kerberos authentication.

- **Used by:** Shared Azure Files orchestration for private-endpoint Entra Kerberos hybrid and Entra
  Kerberos cloud-only configurations
- **Parameters:** `AppDisplayNamePrefix`, `ClientId`, `GraphEndpoint`, `PrivateEndpoint`,
  `EnableCloudGroupSids`
- **Behavior:** Uses Microsoft Graph with managed identity, adds private-link identifier URIs when
  required, and applies the `kdc_enable_cloud_group_sids` tag for cloud-only group authorization.
- **Output:** `C:\Windows\Logs\Update-StorageAccountApplicationManifest-<timestamp>.log`

### [Grant-StorageAccountApplicationConsent.ps1](Grant-StorageAccountApplicationConsent.ps1)

Grants the delegated permissions required by Azure Files Kerberos enterprise applications.

- **Used by:** Shared Azure Files orchestration after NTFS permissions are configured
- **Parameters:** `AppDisplayNamePrefix`, `ClientId`, `GraphEndpoint`
- **Behavior:** Finds matching storage account application and service principal objects through
  Microsoft Graph, then creates or updates their delegated permission grants.
- **Output:** `C:\Windows\Logs\Grant-StorageAccountApplicationConsent-<timestamp>.log`

### [Set-NtfsPermissionsAzureFiles.ps1](Set-NtfsPermissionsAzureFiles.ps1)

Sets NTFS permissions on Azure Files shares used by FSLogix.

- **Used by:** Shared FSLogix orchestration consumed by host pools and the FSLogix Storage add-on
- **Parameters:** Domain credentials and domain name, shares, sharding settings, storage account
  naming and indexing values, storage suffix, managed identity client ID, and user groups
- **Behavior:** Resolves AD groups through an explicitly selected domain controller or converts
  Microsoft Entra object IDs to SIDs for cloud-only identity, mounts each share, and applies ACLs.

### [Set-NtfsPermissionsNetApp.ps1](Set-NtfsPermissionsNetApp.ps1)

Sets NTFS permissions on Azure NetApp Files volumes used by FSLogix.

- **Used by:** Shared FSLogix orchestration for host pool deployments
- **Parameters:** `AdminGroupNames`, `Shares`, domain join credentials, `NetAppServers`,
  `UserGroupNames`
- **Behavior:** Mounts the SMB volumes and applies the requested administrator and user ACLs.

## Deployment Helper Cleanup

### [Remove-RunCommands.ps1](Remove-RunCommands.ps1)

Removes Azure VM Run Command resources from one or more deployment VMs.

- **Used by:** Shared deployment-helper cleanup orchestration
- **Parameters:** `ResourceManagerUri`, `SubscriptionId`, `UserAssignedIdentityClientId`,
  `VirtualMachineNames`, `VirtualMachinesResourceGroup`
- **Behavior:** Authenticates with managed identity, deletes each Run Command, and waits for removal.

### [Remove-RoleAssignments.ps1](Remove-RoleAssignments.ps1)

Removes temporary Azure role assignments created for deployment orchestration.

- **Used by:** Shared deployment-helper cleanup orchestration
- **Parameters:** `ResourceManagerUri`, `RoleAssignmentIds`, `UserAssignedIdentityClientId`

### [Remove-ResourceGroup.ps1](Remove-ResourceGroup.ps1)

Deletes the temporary deployment-helper resource group.

- **Used by:** Shared deployment-helper cleanup orchestration
- **Parameters:** `ResourceManagerUri`, `UserAssignedIdentityClientId`, `ResourceGroupResourceId`

## AVD Control Plane

### [Update-AvdSessionDesktopName.ps1](Update-AvdSessionDesktopName.ps1)

Updates the friendly name of the session desktop in an AVD desktop application group.

- **Used by:** Standard and automated host pool control-plane modules
- **Parameters:** `ApplicationGroupResourceId`, `FriendlyName`, `ResourceManagerUri`,
  `UserAssignedIdentityClientId`

## Execution and Security Conventions

- Scripts are embedded by Bicep and aren't intended as interactive operator utilities.
- Azure REST and Microsoft Graph operations use managed identity rather than stored credentials.
- Cloud endpoints and DNS suffixes are passed by the calling template where required.
- Protected Run Command parameters are used for domain credentials and other sensitive values.
- Every PowerShell file in this directory must remain ASCII-only because scripts are embedded in
  generated ARM JSON.
- Callers treat script failures as deployment failures where a failed operation would leave the
  deployment incomplete or insecure.

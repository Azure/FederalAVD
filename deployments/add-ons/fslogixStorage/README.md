# FSLogix Storage Add-On

This add-on provisions FSLogix storage independently of a FederalAVD host pool deployment. It uses
the same `deployments/hostpools/modules/fslogix-storage/fslogix.bicep` module as the host pool and is
the storage prerequisite for automated host pools configured by the `automatedSessionHostPolicy`
add-on.

## Boundary

The add-on owns profile storage configuration. It does not create a host pool, session host,
deployment VM, policy assignment, Key Vault, Log Analytics workspace, or Recovery Services vault.
Those shared resources are supplied by resource ID or name.

## Capabilities

| Capability | Azure Files | Azure NetApp Files |
| --- | --- | --- |
| AD DS | Yes | Yes |
| Entra Domain Services | Yes | Yes |
| Entra Kerberos Hybrid | Yes | No |
| Entra Kerberos Cloud Only | Yes | No |
| Entra ID with storage keys | Yes | No |
| Share permissions | Default SMB share permission and admin Azure RBAC | Volume configuration |
| NTFS permissions | Deployment VM Run Command | Deployment VM Run Command |
| Private networking | Private endpoint | Delegated subnet |
| Customer-managed keys | Existing Key Vault and identity | Managed by the NetApp account path |
| Diagnostics | Existing Log Analytics workspace | Not configured by the shared module |
| Backup | Existing Recovery Services vault and policy | Not configured by the shared module |

## Required Inputs

- Storage region, resource group, names, and deployment suffix.
- Existing deployment VM name, resource group, and user-assigned identity client ID.
- Storage service, SKU, redundancy, container type, share size, and sharding configuration.
- Identity solution and user/admin groups with both object IDs and display names.
- Private endpoint subnet and Azure Files private DNS zone resource IDs.
- Existing Log Analytics workspace resource ID when diagnostics are enabled.
- Existing Key Vault and storage CMK settings when customer-managed keys are enabled.
- Existing Recovery Services vault and file share policy when backup is enabled.
- Azure NetApp Files account, capacity pool, and delegated subnet settings when ANF is selected.

The deployment VM is required because the shared host-pool modules use Run Command to register
domain-backed storage, update Entra Kerberos applications, grant consent, and initialize NTFS
permissions. The add-on intentionally does not create a general-purpose VM implicitly.

Azure Files uses `StorageFileDataSmbShareContributor` as the default share permission and grants
`Storage File Data Privileged Contributor` to each administrator group. The NTFS initialization
script applies the user-group and sharding restrictions within the shares.

AD DS, Entra Domain Services, Entra Kerberos Hybrid domain configuration, and Azure NetApp Files
require domain credentials. Entra Kerberos Cloud Only and private Entra Kerberos Hybrid deployments
also require the application-update identity used by the host-pool deployment path.

## Required Outputs

The add-on outputs a `fslogixConfiguration` object accepted directly by
`deployments/add-ons/automatedSessionHostPolicy/main.bicep`:

```bicep
output fslogixConfiguration object = {
  configurationVersion: '1.0.0'
  identitySolution: identitySolution
  storageService: storageService
  containerType: containerType
  fileShareNames: fileShareNames
  localStorageAccountResourceIds: storageAccountResourceIds
  remoteStorageAccountResourceIds: remoteStorageAccountResourceIds
  localNetAppServerFqdns: netAppServerFqdns
  remoteNetAppServerFqdns: remoteNetAppServerFqdns
  objectSpecificSettingsGroups: objectSpecificSettingsGroups
  profileSizeInMBs: profileSizeInMBs
}
```

It also outputs Azure Files storage account IDs, Azure NetApp Files volume IDs, and ANF SMB server
FQDNs for monitoring, backup, RBAC, and operational integration.

## Security Requirements

1. Automated session hosts use identity-based SMB authentication for AD DS, Entra Domain Services,
   and Entra Kerberos. Entra ID key mode retrieves keys at deployment time; the add-on never outputs
   storage keys, SAS tokens, or credentials.
2. Public network access is disabled when private endpoints are selected.
3. Customer-managed key resources and role assignments must exist before storage accounts consume
   them.
4. Storage admin and user permissions are assigned to Microsoft Entra groups, not individual users.
5. Domain credentials, when required for storage registration, use secure parameters or Key Vault
   references and are not retained in deployment outputs.

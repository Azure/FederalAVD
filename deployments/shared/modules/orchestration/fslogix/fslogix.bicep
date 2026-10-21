metadata name = 'FSLogix storage orchestration'
metadata description = 'Composes Azure Files or domain-services Azure NetApp Files storage in an existing storage resource group, with optional Azure Files backup registration in an existing vault resource group.'

targetScope = 'subscription'

import { entraGroupType } from '../../resourceModules/types/identityTypes.bicep'
import { publicNetworkAccessMode } from '../networking/functions.bicep'

@description('Required. Whether to configure an Active Directory connection when creating the NetApp account.')
param activeDirectoryConnection bool
@description('Optional. Whether to create the NetApp account; when false, the named account must already exist.')
param createNetAppAccount bool = true
@description('Optional. Whether to create the NetApp capacity pool; when false, the named pool must already exist.')
param createNetAppCapacityPool bool = true
@description('Required. Selected session-host or SMB identity mode used to choose domain, Entra, and storage configuration paths.')
param identitySolution string
@description('Required. Resource ID of an existing Azure Files private DNS zone; empty omits the private endpoint DNS zone group.')
param azureFilePrivateDnsZoneResourceId string
@description('Required. Client ID of the identity attached to the helper VM and authorized for storage configuration.')
param deploymentUserAssignedIdentityClientId string
@description('Required. Name of the existing deployment helper VM used to execute storage or cleanup Run Commands.')
param deploymentVirtualMachineName string
@secure()
@description('Required. Domain account password used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPassword string
@secure()
@description('Required. Domain account UPN used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPrincipalName string
@description('Required. DNS domain name for selected domain operations; otherwise pass an empty string.')
param domainName string
@description('Required. URI of the existing encryption Key Vault, including the trailing slash; used for customer-managed storage keys.')
param encryptionKeyVaultUri string
@description('Required. Array of administrator group objects with id and name; IDs drive Azure Files RBAC and names drive domain share permissions.')
param fslogixAdminGroups entraGroupType[]
@description('Required. Resource ID of the storage application update identity attached to the helper VM; empty skips application manifest and consent commands.')
param appUpdateUserAssignedIdentityResourceId string
@description('Required. Key name pattern containing ## for the two-digit storage account index; used with customer-managed encryption.')
param fslogixEncryptionKeyNameConv string
@description('Required. Array of share name strings in profile-then-Office order, created on each storage account or as individual NetApp volumes.')
param fslogixFileShares array
@description('Required. Sharding selection forwarded to Azure Files permission configuration; None disables sharding.')
param fslogixShardOptions string
@description('Required. Array of user group objects with id and name for identity-dependent share permission configuration.')
param fslogixUserGroups entraGroupType[]
@description('Optional. Resource ID of the associated AVD host pool, used for resource ownership tags.')
param hostPoolResourceId string = ''
@description('Optional. Kerberos ticket encryption selection; RC4 selects RC4-HMAC and other values select AES-256 for Azure Files SMB settings.')
param kerberosEncryptionType string = 'AES256'
@description('Required. Storage encryption mode; PlatformManaged omits customer-managed key configuration.')
param keyManagementStorageAccounts string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Resource ID of an existing Log Analytics workspace; empty omits optional diagnostic settings.')
param logAnalyticsWorkspaceResourceId string
@description('Required. Name of the NetApp account in the storage resource group; must already exist when account creation is disabled.')
param netAppAccountName string
@description('Required. Name of the NetApp capacity pool; must already exist when pool creation is disabled.')
param netAppCapacityPoolName string
@description('Required. Resource ID of the existing delegated subnet for NetApp volumes; its VNet supplies Active Directory DNS servers.')
param netAppVolumesSubnetResourceId string
@description('Required. Distinguished name of the target organizational unit for selected domain operations; empty uses the domain default.')
param ouPath string
@description('Required. Whether to create private endpoints and apply the corresponding public-network restrictions.')
param privateEndpoint bool
@description('Required. Private endpoint name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNameConv string
@description('Required. Private endpoint NIC name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNICNameConv string
@description('Required. Resource ID of the existing subnet for private endpoints; required when endpoint creation is selected.')
param privateEndpointSubnetResourceId string
@description('Required. Name of the existing resource group containing the deployment helper VM.')
param resourceGroupDeployment string
@description('Required. Name of the existing storage resource group in this subscription.')
param resourceGroupStorage string
@description('Required. Quota per file share or NetApp volume in GiB.')
param shareSizeInGB int
@description('Required. Location token appended to anf- for the NetApp Active Directory SMB server name.')
param smbServerLocation string
@description('Required. Prefix for storage account names, followed by a two-digit index starting at storageIndex.')
param storageAccountNamePrefix string
@description('Required. Number of indexed Azure Files storage accounts to create.')
param storageCount int
@description('Required. Starting numeric index for storage account and encryption-key names.')
param storageIndex int
@description('Required. Storage tier: Standard or Premium for Azure Files, or the NetApp service level for NetApp volumes.')
param storageSku string
@description('Required. Azure Files redundancy selection; ZoneRedundant selects ZRS and other values select LRS.')
param fslogixStorageRedundancy string
@description('Required. Storage backend selection: AzureFiles or AzureNetAppFiles; the NetApp path requires a domain-services identity solution.')
param storageSolution string
@description('Required. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object
@description('Optional. Resource ID of the existing identity authorized to use the storage encryption keys; unused for PlatformManaged encryption.')
param encryptionUserAssignedIdentityResourceId string = ''
@description('Optional. Array of permitted IP address or CIDR strings for resource firewalls.')
param permittedIPs string[] = []

@description('Optional. Azure Files public-access mode; Auto preserves legacy private-endpoint/IP inference. Does not apply to NetApp Files or backup vaults.')
param paasPublicNetworkAccess publicNetworkAccessMode = 'Auto'
@description('Optional. Retention interval in days for deleted Azure Files shares.')
param fslogixSoftDeleteRetentionDays int = 14
@description('Optional. Resource ID of an existing Recovery Services vault; empty disables backup registration.')
param recoveryServicesVaultResourceId string = ''
@description('Optional. Name of the existing Azure Files backup policy in the selected Recovery Services vault.')
param fileSharePolicyName string = 'filesharepolicy'

// Azure NetApp files for fslogix
module azureNetAppFiles 'modules/azureNetAppFiles.bicep' = if (storageSolution == 'AzureNetAppFiles' && contains(
  identitySolution,
  'DomainServices'
)) {
  scope: resourceGroup(resourceGroupStorage)
  params: {
    activeDirectoryConnection: activeDirectoryConnection
    createNetAppAccount: createNetAppAccount
    createNetAppCapacityPool: createNetAppCapacityPool
    deploymentVirtualMachineName: deploymentVirtualMachineName
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    shares: fslogixFileShares
    shareSizeInGB: shareSizeInGB
    shareAdminGroups: fslogixAdminGroups
    shareUserGroups: fslogixUserGroups
    location: location
    netAppAccountName: netAppAccountName
    netAppCapacityPoolName: netAppCapacityPoolName
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    ouPath: ouPath
    resourceGroupDeployment: resourceGroupDeployment
    smbServerLocation: smbServerLocation
    storageSku: storageSku
    tagsNetAppAccount: union(
      !empty(hostPoolResourceId) ? { 'cm-resource-parent': hostPoolResourceId } : {},
      tags[?'Microsoft.NetApp/netAppAccounts'] ?? {}
    )
    tagsNetAppCapacityPool: union(
      !empty(hostPoolResourceId) ? { 'cm-resource-parent': hostPoolResourceId } : {},
      tags[?'Microsoft.NetApp/netAppAccounts/capacityPools'] ?? {}
    )
    tagsNetAppVolume: union(
      !empty(hostPoolResourceId) ? { 'cm-resource-parent': hostPoolResourceId } : {},
      tags[?'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'] ?? {}
    )
  }
}

// Azure files for FSLogix
module azureFiles 'modules/azureFiles.bicep' = if (storageSolution == 'AzureFiles') {
  scope: resourceGroup(resourceGroupStorage)
  params: {
    appUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    deploymentResourceGroupName: resourceGroupDeployment
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    fileShares: fslogixFileShares
    fslogixEncryptionKeyNameConv: fslogixEncryptionKeyNameConv
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts == 'PlatformManaged'
      ? ''
      : encryptionUserAssignedIdentityResourceId
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
    kerberosEncryptionType: kerberosEncryptionType
    keyManagementStorageAccounts: keyManagementStorageAccounts
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId
    ouPath: ouPath
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    resourceGroupStorage: resourceGroupStorage
    shardingOptions: fslogixShardOptions
    shareAdminGroups: fslogixAdminGroups
    shareSizeInGB: shareSizeInGB
    shareUserGroups: fslogixUserGroups
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    storageSku: storageSku
    storageRedundancy: fslogixStorageRedundancy
    tags: tags
    permittedIPs: permittedIPs
    paasPublicNetworkAccess: paasPublicNetworkAccess
    softDeleteRetentionDays: fslogixSoftDeleteRetentionDays
  }
}

// Register all Azure Files storage accounts and shares with the Recovery Services Vault for snapshot backup.
// Scoped to the vault's resource group so ARM child resource declarations resolve correctly.
module backupRegistration 'modules/fslogixBackupItems.bicep' = if (storageSolution == 'AzureFiles' && !empty(recoveryServicesVaultResourceId)) {
  scope: resourceGroup(split(recoveryServicesVaultResourceId, '/')[2], split(recoveryServicesVaultResourceId, '/')[4])
  params: {
    vaultName: last(split(recoveryServicesVaultResourceId, '/'))!
    location: location
    fileShares: fslogixFileShares
    storageAccountResourceIds: azureFiles!.outputs.storageAccountResourceIds
    fileSharePolicyName: fileSharePolicyName
    tags: tags
    hostPoolResourceId: hostPoolResourceId
  }
}

@description('The supplied storage encryption identity resource ID, returned unchanged.')
output encryptionUserAssignedIdentityResourceId string = encryptionUserAssignedIdentityResourceId
@description('Created NetApp volume resource IDs in share order, or an empty array for Azure Files.')
output netAppVolumeResourceIds array = storageSolution == 'AzureNetAppFiles'
  ? azureNetAppFiles!.outputs.volumeResourceIds
  : []
@description('NetApp SMB server FQDN strings for the first one or two shares, or an empty array for Azure Files.')
output netAppServerFqdns array = storageSolution == 'AzureNetAppFiles'
  ? azureNetAppFiles!.outputs.smbServerFqdns
  : []
@description('Created Azure Files storage account resource IDs in ascending storage index order; empty for NetApp storage.')
output storageAccountResourceIds array = storageSolution == 'AzureFiles'
  ? azureFiles!.outputs.storageAccountResourceIds
  : []

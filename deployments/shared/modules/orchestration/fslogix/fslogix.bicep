metadata name = 'FSLogix storage orchestration'
metadata description = 'Composes Azure Files or domain-services Azure NetApp Files storage in an existing storage resource group, with optional Azure Files backup registration in an existing vault resource group.'

targetScope = 'subscription'

import { entraGroupType } from '../../resourceModules/types/identityTypes.bicep'
import { publicNetworkAccessMode } from '../networking/functions.bicep'

// Profile is always first so array positions remain stable for storage roles and NetApp volumes.
@export()
func fslogixShareNames(containerType string) string[] => contains(containerType, 'Office')
  ? ['profile-containers', 'office-containers']
  : ['profile-containers']

// OSS is a session-host identity feature, not a storage authentication feature.
// Current EntraKerberos modes create Entra-only hosts; no hybrid-device join mode is exposed.
// https://learn.microsoft.com/fslogix/overview-faq#can-i-use-object-specific-settings-with-microsoft-entra-id-cloud-only-identities-or-microsoft-entra-joined-virtual-machines-and-hybrid-identities
// Storage-only producers do not call this guard because they do not configure session hosts.
@export()
func validateObjectSpecificSettings(identitySolution string, requested bool) bool => !requested || contains(['ActiveDirectoryDomainServices', 'EntraDomainServices'], identitySolution)
  ? true
  : fail('FSLogix Object Specific Settings require AD-domain-joined session hosts. FederalAVD EntraKerberos-Hybrid, EntraKerberos-CloudOnly, and EntraId modes use Entra-only joined hosts. Use ShardPerms with Entra Kerberos instead.')

// Validate caller-supplied account arrays without sorting or deduplicating their shard positions.
// Office counts must match Profile counts in each region; a remote set and selected groups must
// also match the local shard count. Office account names must be unique across both regions and
// disjoint from Profile names. Compare the final resource-ID segment case-insensitively.
// Office-disabled configurations reject leftover Office inputs instead of silently ignoring them.
@export()
func validateOfficeStorageAccounts(localProfile string[], remoteProfile string[], localOffice string[], remoteOffice string[], officeEnabled bool, groups string[]) { local: string[], remote: string[] } => officeEnabled
  ? (!empty(localProfile) && length(localOffice) == length(localProfile) && length(remoteOffice) == length(remoteProfile) && (empty(remoteProfile) || length(remoteProfile) == length(localProfile)) && (empty(groups) || length(groups) == length(localProfile)) && length(union(
        map(concat(localOffice, remoteOffice), id => toLower(last(split(id, '/')))),
        map(concat(localOffice, remoteOffice), id => toLower(last(split(id, '/'))))
      )) == length(concat(localOffice, remoteOffice)) && empty(intersection(
        map(concat(localProfile, remoteProfile), id => toLower(last(split(id, '/')))),
        map(concat(localOffice, remoteOffice), id => toLower(last(split(id, '/'))))
      )))
      ? { local: localOffice, remote: remoteOffice }
      : fail('Office containers require distinct Azure Files accounts paired one-to-one with Profile accounts in shard order.')
  : empty(localOffice) && empty(remoteOffice)
    ? { local: [], remote: [] }
    : fail('Office storage accounts were supplied but Office containers are disabled.')

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
param fslogixProfileEncryptionKeyNameConv string
@description('Required. FSLogix container selection; determines fixed Profile and optional Office share names.')
param fslogixContainerType string
@description('Required. Sharding selection forwarded to Azure Files permission configuration; None disables sharding.')
param fslogixShardOptions string
@description('Required. Array of user group objects with id and name for identity-dependent share permission configuration.')
param fslogixUserGroups entraGroupType[]
@description('Optional. Resource ID of the associated AVD host pool, used for resource ownership tags.')
param hostPoolResourceId string = ''
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
param profileShareSizeInGB int
@description('Required. Location token appended to anf- for the NetApp Active Directory SMB server name.')
param smbServerLocation string
@description('Required. Prefix for storage account names, followed by a two-digit index starting at storageIndex.')
param profileStorageAccountNamePrefix string
@description('Required. Office account prefix, paired with Profile account indices; unused when Office containers are disabled or storage is NetApp.')
param officeStorageAccountNamePrefix string
@description('Required. Office encryption-key pattern containing ##; unused without Office accounts or customer-managed encryption.')
param officeEncryptionKeyNameConv string
@description('Required. Number of indexed Azure Files storage accounts to create.')
param storageCount int
@description('Required. Starting numeric index for storage account and encryption-key names.')
param storageIndex int
@description('Required. Profile Azure Files media: Standard (HDD) or Premium (SSD).')
param profileStorageTier string
@allowed(['Standard', 'Premium'])
@description('Optional. NetApp capacity-pool and volume service level; unused with Azure Files.')
param netAppServiceLevel string = 'Premium'
@description('Optional. Office Azure Files tier; defaults to the Profile tier.')
param officeStorageTier string = profileStorageTier
@description('Optional. Office share quota in GiB; defaults to the Profile quota.')
param officeShareSizeInGB int = profileShareSizeInGB
@description('Required. Azure Files redundancy selection; ZoneRedundant selects ZRS and other values select LRS.')
param profileStorageRedundancy string
@description('Optional. Office Azure Files redundancy; defaults to the Profile redundancy.')
param officeStorageRedundancy string = profileStorageRedundancy
@allowed(['Legacy', 'ProvisionedV2'])
@description('Optional. Profile Azure Files billing model; Legacy preserves existing parameters.')
param profileStorageBillingModel string = 'Legacy'
@allowed(['Legacy', 'ProvisionedV2'])
@description('Optional. Office Azure Files billing model; defaults to Profile.')
param officeStorageBillingModel string = profileStorageBillingModel
@description('Optional. Profile provisioned-v2 IOPS; zero selects the capacity-based recommendation.')
param profileProvisionedIops int = 0
@description('Optional. Profile provisioned-v2 throughput in MiB/s; zero selects the capacity-based recommendation.')
param profileProvisionedThroughputMiBps int = 0
@description('Optional. Office provisioned-v2 IOPS; zero selects the Office capacity-based recommendation.')
param officeProvisionedIops int = 0
@description('Optional. Office provisioned-v2 throughput in MiB/s; zero selects the Office capacity-based recommendation.')
param officeProvisionedThroughputMiBps int = 0
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

var fileShareNames = fslogixShareNames(fslogixContainerType)

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
    containerType: fslogixContainerType
    fileShares: fileShareNames
    shareSizeInGB: profileShareSizeInGB
    shareAdminGroups: fslogixAdminGroups
    shareUserGroups: fslogixUserGroups
    location: location
    netAppAccountName: netAppAccountName
    netAppCapacityPoolName: netAppCapacityPoolName
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    ouPath: ouPath
    resourceGroupDeployment: resourceGroupDeployment
    smbServerLocation: smbServerLocation
    serviceLevel: netAppServiceLevel
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
    fileShares: fileShareNames
    officeStorageAccountNamePrefix: officeStorageAccountNamePrefix
    officeEncryptionKeyNameConv: officeEncryptionKeyNameConv
    officeStorageTier: officeStorageTier
    officeStorageRedundancy: officeStorageRedundancy
    officeShareSizeInGB: officeShareSizeInGB
    profileStorageBillingModel: profileStorageBillingModel
    officeStorageBillingModel: officeStorageBillingModel
    profileProvisionedIops: profileProvisionedIops
    profileProvisionedThroughputMiBps: profileProvisionedThroughputMiBps
    officeProvisionedIops: officeProvisionedIops
    officeProvisionedThroughputMiBps: officeProvisionedThroughputMiBps
    fslogixProfileEncryptionKeyNameConv: fslogixProfileEncryptionKeyNameConv
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts == 'PlatformManaged'
      ? ''
      : encryptionUserAssignedIdentityResourceId
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
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
    profileShareSizeInGB: profileShareSizeInGB
    shareUserGroups: fslogixUserGroups
    profileStorageAccountNamePrefix: profileStorageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    profileStorageTier: profileStorageTier
    profileStorageRedundancy: profileStorageRedundancy
    tags: tags
    permittedIPs: permittedIPs
    paasPublicNetworkAccess: paasPublicNetworkAccess
    softDeleteRetentionDays: fslogixSoftDeleteRetentionDays
  }
}

// Register only Profile Azure Files accounts and their fixed Profile share for snapshot backup.
// Scoped to the vault's resource group so ARM child resource declarations resolve correctly.
module backupRegistration 'modules/fslogixBackupItems.bicep' = if (storageSolution == 'AzureFiles' && !empty(recoveryServicesVaultResourceId)) {
  scope: resourceGroup(split(recoveryServicesVaultResourceId, '/')[2], split(recoveryServicesVaultResourceId, '/')[4])
  params: {
    vaultName: last(split(recoveryServicesVaultResourceId, '/'))!
    location: location
    fileShares: ['profile-containers']
    profileStorageAccountResourceIds: azureFiles!.outputs.profileStorageAccountResourceIds
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
@description('Created Profile Azure Files account IDs in ascending shard index order; empty for NetApp storage.')
output profileStorageAccountResourceIds array = storageSolution == 'AzureFiles'
  ? azureFiles!.outputs.profileStorageAccountResourceIds
  : []
@description('Created Office Azure Files account IDs, paired by index with Profile accounts; empty when disabled or using NetApp.')
output officeStorageAccountResourceIds array = storageSolution == 'AzureFiles'
  ? azureFiles!.outputs.officeStorageAccountResourceIds
  : []

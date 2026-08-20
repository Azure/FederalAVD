targetScope = 'subscription'

type entraGroupType = {
  @description('Microsoft Entra object ID of the group.')
  id: string
  @description('Display name of the group.')
  name: string
}

@description('Required. Azure region for FSLogix storage resources and deployment VM Run Commands.')
param location string

@description('Required. Resource group where FSLogix storage resources are deployed.')
param storageResourceGroupName string

@description('Required. Resource group containing the existing deployment VM.')
param deploymentResourceGroupName string

@description('Required. Name of the existing deployment VM used for domain, application, and NTFS configuration.')
param deploymentVirtualMachineName string

@description('Required. Client ID of the deployment VM user-assigned identity used by storage configuration scripts.')
param deploymentUserAssignedIdentityClientId string

@description('Required. Identity and storage authentication model.')
@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraKerberos-Hybrid'
  'EntraKerberos-CloudOnly'
  'EntraId'
])
param identitySolution string

@description('Optional. Domain join account UPN. Required for AD DS, Entra Domain Services, Entra Kerberos Hybrid domain configuration, and Azure NetApp Files.')
@secure()
param domainJoinUserPrincipalName string = ''

@description('Optional. Domain join account password.')
@secure()
param domainJoinUserPassword string = ''

@description('Optional. AD DS domain name used by domain-backed identity solutions.')
param domainName string = ''

@description('Optional. OU path for storage computer objects.')
param organizationalUnitPath string = ''

@description('Optional. Existing user-assigned identity resource ID with permissions to update and consent to storage account enterprise applications for Entra Kerberos.')
param appUpdateUserAssignedIdentityResourceId string = ''

@description('Required. FSLogix storage service and SKU.')
@allowed([
  'AzureFiles Premium'
  'AzureFiles Standard'
  'AzureNetAppFiles Premium'
  'AzureNetAppFiles Standard'
])
param fslogixStorageService string = 'AzureFiles Standard'

@description('Optional. Storage redundancy for Azure Files.')
@allowed([
  'LocallyRedundant'
  'ZoneRedundant'
])
param fslogixStorageRedundancy string = 'LocallyRedundant'

@description('Optional. FSLogix container layout.')
@allowed([
  'CloudCacheProfileContainer'
  'CloudCacheProfileOfficeContainer'
  'ProfileContainer'
  'ProfileOfficeContainer'
])
param fslogixContainerType string = 'ProfileContainer'

@description('Optional. Profile container size configured on session hosts, in MB.')
@minValue(1)
param profileSizeInMBs int = 30000

@description('Optional. File share or Azure NetApp Files volume size, in GB.')
@minValue(1)
param shareSizeInGB int = 100

@description('Optional. Azure Files storage sharding and permission model.')
@allowed([
  'None'
  'ShardOSS'
  'ShardPerms'
])
param fslogixShardOptions string = 'None'

@description('Optional. Groups granted administrative access to FSLogix storage.')
param fslogixAdminGroups entraGroupType[] = []

@description('Optional. Groups granted user access to FSLogix storage and used for sharding.')
param fslogixUserGroups entraGroupType[] = []

@description('Required. Lowercase alphanumeric Azure Files storage account name prefix. The module appends a two-digit index.')
@minLength(1)
@maxLength(22)
param storageAccountNamePrefix string

@description('Optional. Starting index appended to Azure Files storage account names.')
@minValue(0)
@maxValue(99)
param storageIndex int = 1

@description('Required. Unique suffix for nested deployment names.')
param deploymentSuffix string

@description('Optional. Resource ID recorded as the Cost Management parent tag on deployed resources.')
param parentResourceId string = ''

@description('Optional. Deploy private endpoints for Azure Files storage accounts.')
param privateEndpoint bool = true

@description('Optional. Resource ID of the subnet used by Azure Files private endpoints.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Resource ID of the Azure Files private DNS zone.')
param azureFilePrivateDnsZoneResourceId string = ''

@description('Required when privateEndpoint is true. Naming convention for private endpoints. Supports RESOURCE, SUBRESOURCE, and VNETID tokens.')
param privateEndpointNameConvention string = 'pe-RESOURCE-SUBRESOURCE-VNETID'

@description('Required when privateEndpoint is true. Naming convention for private endpoint NICs. Supports RESOURCE, SUBRESOURCE, and VNETID tokens.')
param privateEndpointNicNameConvention string = 'nic-RESOURCE-SUBRESOURCE-VNETID'

@description('Optional. IP addresses or CIDR blocks permitted through the Azure Files firewall.')
param permittedIPs string[] = []

@description('Optional. Resource ID of an existing Log Analytics workspace for storage diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Storage encryption key management mode.')
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorage string = 'PlatformManaged'

@description('Optional. Key Vault URI ending in a slash for Azure Files customer-managed keys.')
param encryptionKeyVaultUri string = ''

@description('Optional. FSLogix storage encryption key naming convention. Use ## as the storage index token.')
param fslogixEncryptionKeyNameConvention string = 'key-fsl-##'

@description('Optional. Resource ID of the user-assigned identity used by Azure Files customer-managed encryption.')
param encryptionUserAssignedIdentityResourceId string = ''

@description('Optional. Number of days to retain deleted Azure file shares.')
@minValue(1)
@maxValue(365)
param softDeleteRetentionDays int = 14

@description('Optional. Kerberos encryption type used by Azure Files domain authentication.')
@allowed([
  'AES256'
  'RC4'
])
param kerberosEncryptionType string = 'AES256'

@description('Optional. Resource ID of an existing Recovery Services vault used for Azure Files backup.')
param recoveryServicesVaultResourceId string = ''

@description('Optional. Name of the Azure Files backup policy in the Recovery Services vault.')
param fileSharePolicyName string = 'filesharepolicy'

@description('Optional. Indicates that the Azure NetApp account already has the required Active Directory connection.')
param existingSharedActiveDirectoryConnection bool = false

@description('Optional. Azure NetApp Files account name.')
param netAppAccountName string = 'anf-fslogix'

@description('Optional. Azure NetApp Files capacity pool name.')
param netAppCapacityPoolName string = 'pool-fslogix'

@description('Optional. Resource ID of the subnet delegated to Microsoft.NetApp/volumes.')
param netAppVolumesSubnetResourceId string = ''

@description('Optional. Short location token used in the Azure NetApp Files SMB server name.')
param smbServerLocation string = location

@description('Optional. Existing remote Azure Files storage account resource IDs included in the session-host configuration output.')
param remoteStorageAccountResourceIds string[] = []

@description('Optional. Existing remote Azure NetApp Files SMB server FQDNs included in the session-host configuration output.')
param remoteNetAppServerFqdns string[] = []

@description('Optional. Version marker used by the FSLogix policy compliance check.')
param configurationVersion string = '1.0.0'

@description('Optional. Tags keyed by Azure resource type, matching the host pool deployment tag contract.')
param tags object = {}

var fslogixShareNamesLookup = {
  CloudCacheProfileContainer: [
    'profile-containers'
  ]
  CloudCacheProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
  ProfileContainer: [
    'profile-containers'
  ]
  ProfileOfficeContainer: [
    'profile-containers'
    'office-containers'
  ]
}

var storageSolution = split(fslogixStorageService, ' ')[0]
var storageSku = split(fslogixStorageService, ' ')[1]
var fileShareNames = fslogixShareNamesLookup[fslogixContainerType]
var storageCount = identitySolution == 'EntraId' || fslogixShardOptions == 'None' ? 1 : length(fslogixUserGroups)
var shardingConfigurationIsValid = fslogixShardOptions == 'None' || !empty(fslogixUserGroups)
  ? true
  : bool('fslogixUserGroups must contain at least one group when sharding is enabled.')

module fslogix '../../hostpools/modules/fslogix-storage/fslogix.bicep' = {
  params: {
    activeDirectoryConnection: existingSharedActiveDirectoryConnection
    appUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionUserAssignedIdentityResourceId: encryptionUserAssignedIdentityResourceId
    fileSharePolicyName: fileSharePolicyName
    fslogixAdminGroups: fslogixAdminGroups
    fslogixEncryptionKeyNameConv: fslogixEncryptionKeyNameConvention
    fslogixFileShares: fileShareNames
    fslogixShardOptions: shardingConfigurationIsValid ? fslogixShardOptions : fslogixShardOptions
    fslogixSoftDeleteRetentionDays: softDeleteRetentionDays
    fslogixStorageRedundancy: fslogixStorageRedundancy
    fslogixUserGroups: fslogixUserGroups
    hostPoolResourceId: parentResourceId
    identitySolution: identitySolution
    kerberosEncryptionType: kerberosEncryptionType
    keyManagementStorageAccounts: keyManagementStorage
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    netAppAccountName: netAppAccountName
    netAppCapacityPoolName: netAppCapacityPoolName
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    ouPath: organizationalUnitPath
    permittedIPs: permittedIPs
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: privateEndpointNameConvention
    privateEndpointNICNameConv: privateEndpointNicNameConvention
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    recoveryServicesVaultResourceId: recoveryServicesVaultResourceId
    resourceGroupDeployment: deploymentResourceGroupName
    resourceGroupStorage: storageResourceGroupName
    shareSizeInGB: shareSizeInGB
    smbServerLocation: smbServerLocation
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    storageSku: storageSku
    storageSolution: storageSolution
    tags: tags
    deploymentSuffix: deploymentSuffix
  }
}

output fslogixConfiguration object = {
  configurationVersion: configurationVersion
  identitySolution: identitySolution
  storageService: storageSolution
  containerType: fslogixContainerType
  fileShareNames: fileShareNames
  localStorageAccountResourceIds: fslogix.outputs.storageAccountResourceIds
  remoteStorageAccountResourceIds: remoteStorageAccountResourceIds
  localNetAppServerFqdns: fslogix.outputs.netAppServerFqdns
  remoteNetAppServerFqdns: remoteNetAppServerFqdns
  objectSpecificSettingsGroups: fslogixShardOptions == 'ShardOSS' ? map(fslogixUserGroups, group => group.name) : []
  profileSizeInMBs: profileSizeInMBs
}
output netAppServerFqdns array = fslogix.outputs.netAppServerFqdns
output netAppVolumeResourceIds array = fslogix.outputs.netAppVolumeResourceIds
output storageAccountResourceIds array = fslogix.outputs.storageAccountResourceIds
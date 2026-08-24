targetScope = 'subscription'

type entraGroupType = {
  @description('Microsoft Entra object ID of the group.')
  id: string
  @description('Display name of the group.')
  name: string
}

@description('Required. Azure region for FSLogix storage resources and deployment VM Run Commands.')
param location string

@description('Optional. Identifier used by the shared FederalAVD naming convention.')
param identifier string = 'fslogix'

@description('Optional. Naming convention used to derive resource names when explicit overrides are not supplied.')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Optional. Resource group where FSLogix storage resources are deployed. Required for an existing resource group; overrides the generated name for a new resource group.')
param storageResourceGroupName string = ''

@description('Optional. Create the FSLogix storage resource group before deploying storage resources.')
param createStorageResourceGroup bool = false

@description('Optional. Name override for the temporary resource group created for the deployment VM and identity. The resource group is deleted after storage configuration completes.')
param deploymentResourceGroupName string = ''

@description('Optional. Name override for the temporary deployment VM used for domain, application, and NTFS configuration.')
param deploymentVirtualMachineName string = ''

@description('Optional. Name override for the temporary deployment VM operating system disk.')
param deploymentVirtualMachineDiskName string = ''

@description('Optional. Name override for the temporary deployment VM network interface.')
param deploymentVirtualMachineNicName string = ''

@description('Optional. Size of the temporary deployment VM.')
param deploymentVirtualMachineSize string = 'Standard_B2s'

@description('Required. Resource ID of the subnet used by the temporary deployment VM. The subnet must have network line of sight to domain controllers and private storage endpoints when required.')
param deploymentVirtualMachineSubnetResourceId string

@description('Optional. Name override for the temporary user-assigned identity used by storage configuration and cleanup scripts.')
param deploymentUserAssignedIdentityName string = ''

@description('Required. Identity and storage authentication model.')
@allowed([
  'ActiveDirectoryDomainServices'
  'EntraDomainServices'
  'EntraKerberos-Hybrid'
  'EntraKerberos-CloudOnly'
  'EntraId'
])
param identitySolution string

@description('Optional. Resource ID of the Key Vault containing DomainJoinUserPrincipalName and DomainJoinUserPassword secrets. Required when the selected identity or storage service uses domain credentials.')
param credentialsKeyVaultResourceId string = ''

@description('Optional. Domain account UPN. Required for AD DS and Azure NetApp Files, and for Entra Kerberos Hybrid only when AD group names must be resolved for NTFS permissions or sharding.')
@secure()
param domainJoinUserPrincipalName string = ''

@description('Optional. Domain join account password.')
@secure()
param domainJoinUserPassword string = ''

@description('Optional. AD DS domain name used by domain-backed identity solutions.')
param domainName string = ''

@description('Optional. OU path for storage computer objects.')
param organizationalUnitPath string = ''

@description('Optional. OU path used when the temporary deployment VM must be domain joined for Azure NetApp Files configuration.')
param deploymentVirtualMachineOrganizationalUnitPath string = ''

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

@description('Optional. Lowercase alphanumeric Azure Files storage account name prefix override. The module appends a two-digit index.')
@maxLength(13)
param storageAccountNamePrefix string = ''

@description('Optional. Starting index appended to Azure Files storage account names.')
@minValue(0)
@maxValue(99)
param storageIndex int = 1

@description('Optional. Unique suffix for nested deployment names and deployment VM extension reruns.')
param deploymentSuffix string = utcNow('yyyyMMddHHmmss')

@description('Optional. Resource ID recorded as the Cost Management parent tag on deployed resources.')
param parentResourceId string = ''

@description('Optional. Deploy private endpoints for Azure Files storage accounts.')
param privateEndpoint bool = true

@description('Optional. Resource ID of the subnet used by Azure Files private endpoints.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Resource ID of the Azure Files private DNS zone.')
param azureFilePrivateDnsZoneResourceId string = ''

@description('Required when privateEndpoint is true. Naming convention for private endpoints. Supports RESOURCE, SUBRESOURCE, and VNETID tokens.')
param privateEndpointNameConvention string = ''

@description('Required when privateEndpoint is true. Naming convention for private endpoint NICs. Supports RESOURCE, SUBRESOURCE, and VNETID tokens.')
param privateEndpointNicNameConvention string = ''

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

@description('Optional. Resource ID of the existing Key Vault where Azure Files customer-managed keys are created.')
param existingEncryptionKeyVaultResourceId string = ''

@description('Optional. Number of days before Azure Files customer-managed keys expire and rotate.')
@minValue(7)
param keyExpirationInDays int = 180

@description('Optional. Name override for the user-assigned identity created for Azure Files customer-managed encryption.')
param encryptionUserAssignedIdentityName string = ''

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

@description('Optional. Controls whether the Azure NetApp Files account and capacity pool are created or reused. Volumes are always created.')
@allowed([
  'CreateAll'
  'ExistingAccountNewPool'
  'ExistingAccountAndPool'
])
param netAppDeploymentMode string = 'CreateAll'

@description('Optional. Azure NetApp Files account name.')
param netAppAccountName string = ''

@description('Optional. Azure NetApp Files capacity pool name.')
param netAppCapacityPoolName string = ''

@description('Optional. Resource ID of the subnet delegated to Microsoft.NetApp/volumes.')
param netAppVolumesSubnetResourceId string = ''

@description('Optional. Short location token used in the Azure NetApp Files SMB server name.')
param smbServerLocation string = ''

@description('Optional. Existing remote Azure Files storage account resource IDs included in the session-host configuration output.')
param remoteStorageAccountResourceIds string[] = []

@description('Optional. Existing remote Azure NetApp Files SMB server FQDNs included in the session-host configuration output.')
param remoteNetAppServerFqdns string[] = []

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
var effectiveStorageResourceGroupName = !empty(storageResourceGroupName) ? storageResourceGroupName : naming.outputs.resourceGroupStorage
var effectiveDeploymentResourceGroupName = !empty(deploymentResourceGroupName) ? deploymentResourceGroupName : naming.outputs.resourceGroupDeployment
var effectiveDeploymentVirtualMachineName = !empty(deploymentVirtualMachineName) ? deploymentVirtualMachineName : naming.outputs.depVirtualMachineName
var effectiveDeploymentVirtualMachineDiskName = !empty(deploymentVirtualMachineDiskName) ? deploymentVirtualMachineDiskName : naming.outputs.depVirtualMachineDiskName
var effectiveDeploymentVirtualMachineNicName = !empty(deploymentVirtualMachineNicName) ? deploymentVirtualMachineNicName : naming.outputs.depVirtualMachineNicName
var effectiveDeploymentUserAssignedIdentityName = !empty(deploymentUserAssignedIdentityName)
  ? deploymentUserAssignedIdentityName
  : replace(naming.outputs.userAssignedIdentityNameConv, 'TOKEN', 'deployment')
var effectiveStorageAccountNamePrefix = !empty(storageAccountNamePrefix) ? storageAccountNamePrefix : naming.outputs.fslogixStorageAccountNamePrefix
var effectivePrivateEndpointNameConvention = !empty(privateEndpointNameConvention) ? privateEndpointNameConvention : naming.outputs.privateEndpointNameConv
var effectivePrivateEndpointNicNameConvention = !empty(privateEndpointNicNameConvention) ? privateEndpointNicNameConvention : naming.outputs.privateEndpointNICNameConv
var effectiveEncryptionUserAssignedIdentityName = !empty(encryptionUserAssignedIdentityName)
  ? encryptionUserAssignedIdentityName
  : replace(naming.outputs.userAssignedIdentityNameConv, 'TOKEN', 'storage${naming.outputs.delimiter}cmk')
var effectiveNetAppAccountName = !empty(netAppAccountName) ? netAppAccountName : naming.outputs.netAppAccountName
var effectiveNetAppCapacityPoolName = !empty(netAppCapacityPoolName) ? netAppCapacityPoolName : naming.outputs.netAppCapacityPoolName
var effectiveSmbServerLocation = !empty(smbServerLocation) ? smbServerLocation : naming.outputs.vmsLocAbbr
var fileShareNames = fslogixShareNamesLookup[fslogixContainerType]
var storageCount = identitySolution == 'EntraId' || fslogixShardOptions == 'None' ? 1 : length(fslogixUserGroups)
var shardingConfigurationIsValid = fslogixShardOptions == 'None' || !empty(fslogixUserGroups)
  ? true
  : bool('fslogixUserGroups must contain at least one group when sharding is enabled.')
var storageIdentityConfigurationIsValid = storageSolution != 'AzureNetAppFiles' || contains(identitySolution, 'DomainServices')
  ? true
  : bool('Azure NetApp Files requires ActiveDirectoryDomainServices or EntraDomainServices.')
var netAppResourceGroupConfigurationIsValid = storageSolution != 'AzureNetAppFiles' || netAppDeploymentMode == 'CreateAll' || !createStorageResourceGroup
  ? true
  : bool('An existing storage resource group is required when reusing an Azure NetApp Files account or capacity pool.')
var resourceGroupNamesAreDistinct = toLower(effectiveStorageResourceGroupName) != toLower(effectiveDeploymentResourceGroupName)
  ? true
  : bool('The temporary deployment resource group must differ from the storage resource group because cleanup deletes the entire temporary group.')
var deployStorageCmk = storageSolution == 'AzureFiles' && contains(keyManagementStorage, 'CustomerManaged')
var storageCmkConfigurationIsValid = !deployStorageCmk || !empty(existingEncryptionKeyVaultResourceId)
  ? true
  : bool('existingEncryptionKeyVaultResourceId is required when Azure Files uses customer-managed keys.')
var domainCredentialsRequired = contains(identitySolution, 'DomainServices') || storageSolution == 'AzureNetAppFiles' || (identitySolution == 'EntraKerberos-Hybrid' && !empty(fslogixUserGroups))

module naming '../../hostpools/modules/naming.bicep' = {
  params: {
    namingConvention: namingConvention
    virtualMachinesRegion: location
    identifier: identifier
  }
}

resource credentialsKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(credentialsKeyVaultResourceId)) {
  name: last(split(credentialsKeyVaultResourceId, '/'))
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
}

resource encryptionKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (deployStorageCmk && !empty(existingEncryptionKeyVaultResourceId)) {
  name: last(split(existingEncryptionKeyVaultResourceId, '/'))
  scope: resourceGroup(split(existingEncryptionKeyVaultResourceId, '/')[2], split(existingEncryptionKeyVaultResourceId, '/')[4])
}

module storageResourceGroup '../../shared/modules/resources/resourceGroups/deploy.bicep' = if (createStorageResourceGroup) {
  params: {
    name: effectiveStorageResourceGroupName
    location: location
    tags: union(
      tags[?'Microsoft.Resources/resourceGroups'] ?? {},
      empty(parentResourceId) ? {} : { 'cm-resource-parent': parentResourceId }
    )
  }
}

module deploymentResourceGroup '../../shared/modules/resources/resourceGroups/deploy.bicep' = {
  params: {
    name: resourceGroupNamesAreDistinct ? effectiveDeploymentResourceGroupName : effectiveDeploymentResourceGroupName
    location: location
    tags: union(
      tags[?'Microsoft.Resources/resourceGroups'] ?? {},
      empty(parentResourceId) ? {} : { 'cm-resource-parent': parentResourceId }
    )
  }
}

module deployment './modules/deployment.bicep' = {
  params: {
    location: location
    deploymentResourceGroupName: effectiveDeploymentResourceGroupName
    deploymentSuffix: deploymentSuffix
    deploymentUserAssignedIdentityName: effectiveDeploymentUserAssignedIdentityName
    deploymentVirtualMachineName: effectiveDeploymentVirtualMachineName
    deploymentVirtualMachineDiskName: effectiveDeploymentVirtualMachineDiskName
    deploymentVirtualMachineNicName: effectiveDeploymentVirtualMachineNicName
    deploymentVirtualMachineSize: deploymentVirtualMachineSize
    deploymentVirtualMachineSubnetResourceId: deploymentVirtualMachineSubnetResourceId
    storageResourceGroupName: effectiveStorageResourceGroupName
    domainJoinDeploymentVirtualMachine: storageSolution == 'AzureNetAppFiles'
    identitySolution: identitySolution
    domainName: domainName
    organizationalUnitPath: !empty(deploymentVirtualMachineOrganizationalUnitPath)
      ? deploymentVirtualMachineOrganizationalUnitPath
      : organizationalUnitPath
    appUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    parentResourceId: parentResourceId
    tags: tags
    #disable-next-line BCP422
    domainJoinUserPrincipalName: domainCredentialsRequired
      ? !empty(domainJoinUserPrincipalName)
        ? domainJoinUserPrincipalName
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPassword: domainCredentialsRequired
      ? !empty(domainJoinUserPassword)
        ? domainJoinUserPassword
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPassword') : ''
      : ''
  }
  dependsOn: [
    deploymentResourceGroup
    storageResourceGroup
  ]
}

module storageCmk '../../hostpools/modules/cmk/storageCmk.bicep' = if (deployStorageCmk && storageCmkConfigurationIsValid) {
  params: {
    resourceGroupName: effectiveStorageResourceGroupName
    keyVaultResourceId: existingEncryptionKeyVaultResourceId
    keyManagementType: contains(keyManagementStorage, 'HSM') ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    parentResourceId: parentResourceId
    deploymentSuffix: deploymentSuffix
    storageKeyNames: [
      for i in range(0, storageCount): replace(naming.outputs.encryptionKeyNameFSLogix, '##', padLeft(i + storageIndex, 2, '0'))
    ]
    identityName: effectiveEncryptionUserAssignedIdentityName
  }
  dependsOn: [storageResourceGroup]
}

module fslogix '../../shared/modules/fslogix/fslogix.bicep' = {
  params: {
    activeDirectoryConnection: storageIdentityConfigurationIsValid && netAppResourceGroupConfigurationIsValid
      ? netAppDeploymentMode == 'CreateAll' || existingSharedActiveDirectoryConnection
      : existingSharedActiveDirectoryConnection
    createNetAppAccount: netAppDeploymentMode == 'CreateAll'
    createNetAppCapacityPool: netAppDeploymentMode != 'ExistingAccountAndPool'
    appUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: deployment.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deployment.outputs.virtualMachineName
    #disable-next-line BCP422
    domainJoinUserPassword: domainCredentialsRequired
      ? !empty(domainJoinUserPassword)
        ? domainJoinUserPassword
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPassword') : ''
      : ''
    #disable-next-line BCP422
    domainJoinUserPrincipalName: domainCredentialsRequired
      ? !empty(domainJoinUserPrincipalName)
        ? domainJoinUserPrincipalName
        : !empty(credentialsKeyVaultResourceId) ? credentialsKeyVault!.getSecret('DomainJoinUserPrincipalName') : ''
      : ''
    domainName: domainName
    #disable-next-line BCP318
    encryptionKeyVaultUri: deployStorageCmk ? encryptionKeyVault!.properties.vaultUri : ''
    encryptionUserAssignedIdentityResourceId: deployStorageCmk ? storageCmk!.outputs.storageEncryptionIdentityResourceId : ''
    fileSharePolicyName: fileSharePolicyName
    fslogixAdminGroups: fslogixAdminGroups
    fslogixEncryptionKeyNameConv: naming.outputs.encryptionKeyNameFSLogix
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
    netAppAccountName: effectiveNetAppAccountName
    netAppCapacityPoolName: effectiveNetAppCapacityPoolName
    netAppVolumesSubnetResourceId: netAppVolumesSubnetResourceId
    ouPath: organizationalUnitPath
    permittedIPs: permittedIPs
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: effectivePrivateEndpointNameConvention
    privateEndpointNICNameConv: effectivePrivateEndpointNicNameConvention
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    recoveryServicesVaultResourceId: recoveryServicesVaultResourceId
    resourceGroupDeployment: effectiveDeploymentResourceGroupName
    resourceGroupStorage: effectiveStorageResourceGroupName
    shareSizeInGB: shareSizeInGB
    smbServerLocation: effectiveSmbServerLocation
    storageAccountNamePrefix: effectiveStorageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    storageSku: storageSku
    storageSolution: storageSolution
    tags: tags
    deploymentSuffix: deploymentSuffix
  }
  dependsOn: [storageResourceGroup]
}

module cleanUp './modules/fslogixCleanup.bicep' = {
  params: {
    location: location
    deploymentResourceGroupName: effectiveDeploymentResourceGroupName
    deploymentSuffix: deploymentSuffix
    deploymentUserAssignedIdentityClientId: deployment.outputs.deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deployment.outputs.virtualMachineName
    externalRoleAssignmentResourceIds: deployment.outputs.externalRoleAssignmentResourceIds
  }
  dependsOn: [fslogix]
}

output fslogixConfiguration object = {
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

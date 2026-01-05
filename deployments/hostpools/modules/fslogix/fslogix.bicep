targetScope = 'subscription'

param activeDirectoryConnection bool
param identitySolution string
param availability string
param azureBackupPrivateDnsZoneResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param deploymentSuffix string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param encryptionKeyVaultResourceId string
param encryptionKeyVaultUri string
param fslogixAdminGroups array
param appUpdateUserAssignedIdentityResourceId string
param fslogixEncryptionKeyNameConv string
param fslogixFileShares array
param fslogixShardOptions string
param fslogixUserGroups array
param hostPoolResourceId string
param kerberosEncryptionType string
param keyExpirationInDays int
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceResourceId string
param netAppAccountName string
param netAppCapacityPoolName string
param netAppVolumesSubnetResourceId string
param ouPath string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param recoveryServices bool
param recoveryServicesVaultName string
param resourceGroupDeployment string
param resourceGroupStorage string
param shareSizeInGB int
param smbServerLocation string
param storageAccountNamePrefix string
param storageCount int
param storageIndex int
param storageSku string
param storageSolution string
param tags object
param timeZone string
param userAssignedIdentityNameConv string

module customerManagedKeys 'modules/customerManagedKeys.bicep' = if (storageSolution == 'AzureFiles' && keyManagementStorageAccounts != 'MicrosoftManaged') {
  name: 'Customer-Managed-Keys-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupStorage)
  params: {
    deploymentResourceGroupName: resourceGroupDeployment
    deploymentVirtualMachineName: deploymentVirtualMachineName
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    hostPoolResourceId: hostPoolResourceId
    keyExpirationInDays: keyExpirationInDays
    keyManagementStorageAccounts: keyManagementStorageAccounts
    keyVaultResourceId: encryptionKeyVaultResourceId
    location: location
    storageCount: storageCount
    storageIndex: storageIndex
    tags: tags
    deploymentSuffix: deploymentSuffix
    userAssignedIdentityNameConv: userAssignedIdentityNameConv
    fslogixEncryptionKeyNameConv: fslogixEncryptionKeyNameConv
  }
}

// Azure NetApp files for fslogix
module azureNetAppFiles 'modules/azureNetAppFiles.bicep' = if (storageSolution == 'AzureNetAppFiles' && contains(
  identitySolution,
  'DomainServices'
)) {
  name: 'Azure-NetAppFiles-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupStorage)
  params: {
    activeDirectoryConnection: activeDirectoryConnection
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
      { 'cm-resource-parent': hostPoolResourceId },
      tags[?'Microsoft.NetApp/netAppAccounts'] ?? {}
    )
    deploymentSuffix: deploymentSuffix
  }
}

// Azure files for FSLogix
module azureFiles 'modules/azureFiles.bicep' = if (storageSolution == 'AzureFiles') {
  name: 'Azure-Files-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupStorage)
  params: {
    appUpdateUserAssignedIdentityResourceId: appUpdateUserAssignedIdentityResourceId
    availability: availability
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    deploymentResourceGroupName: resourceGroupDeployment
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts == 'MicrosoftManaged'
      ? ''
      : customerManagedKeys!.outputs.userAssignedIdentityResourceId
    fileShares: fslogixFileShares
    fslogixEncryptionKeyNameConv: fslogixEncryptionKeyNameConv
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
    recoveryServices: recoveryServices
    recoveryServicesVaultName: recoveryServicesVaultName
    resourceGroupStorage: resourceGroupStorage
    shardingOptions: fslogixShardOptions
    shareAdminGroups: fslogixAdminGroups
    shareSizeInGB: shareSizeInGB
    shareUserGroups: fslogixUserGroups
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    storageSku: storageSku
    tags: tags
    deploymentSuffix: deploymentSuffix
    timeZone: timeZone
  }
}

output encryptionUserAssignedIdentityResourceId string = keyManagementStorageAccounts != 'MicrosoftManaged'
  ? customerManagedKeys!.outputs.userAssignedIdentityResourceId
  : ''
output netAppVolumeResourceIds array = storageSolution == 'AzureNetAppFiles'
  ? azureNetAppFiles!.outputs.volumeResourceIds
  : []
output storageAccountResourceIds array = storageSolution == 'AzureFiles'
  ? azureFiles!.outputs.storageAccountResourceIds
  : []

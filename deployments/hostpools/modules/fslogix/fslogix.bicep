targetScope = 'subscription'

param activeDirectoryConnection bool
param identitySolution string
param availability string
param azureBackupPrivateDnsZoneResourceId string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
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
param fslogixEncryptionKeyNameConv string
param fslogixFileShares array
param fslogixShardOptions string
param fslogixUserGroups array
param functionAppDelegatedSubnetResourceId string
param hostPoolResourceId string
param increaseQuota bool
param increaseQuotaAppInsightsName string
param increaseQuotaEncryptionKeyName string
param increaseQuotaFunctionAppName string
param increaseQuotaStorageAccountName string
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
param privateLinkScopeResourceId string
param recoveryServices bool
param recoveryServicesVaultName string
param resourceGroupDeployment string
param resourceGroupStorage string
param serverFarmId string
param shareSizeInGB int
param smbServerLocation string
param storageAccountNamePrefix string
param storageCount int
param storageIndex int
param storageSku string
param storageSolution string
param tags object
param timeStamp string
param timeZone string
param userAssignedIdentityNameConv string

module customerManagedKeys 'modules/customerManagedKeys.bicep' = if (storageSolution == 'AzureFiles' && keyManagementStorageAccounts != 'MicrosoftManaged') {
  name: 'CustomerManagedKeys_${timeStamp}'
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
    timeStamp: timeStamp
    userAssignedIdentityNameConv: userAssignedIdentityNameConv
    fslogixEncryptionKeyNameConv: fslogixEncryptionKeyNameConv
    increaseQuotaEncryptionKeyName: increaseQuotaEncryptionKeyName
    increaseQuota: increaseQuota
  }
}

// Azure NetApp files for fslogix
module azureNetAppFiles 'modules/azureNetAppFiles.bicep' = if (storageSolution == 'AzureNetAppFiles' && contains(
  identitySolution,
  'DomainServices'
)) {
  name: 'AzureNetAppFiles_${timeStamp}'
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
    storageSolution: storageSolution
    tagsNetAppAccount: union(
      { 'cm-resource-parent': hostPoolResourceId },
      tags[?'Microsoft.NetApp/netAppAccounts'] ?? {}
    )
    timeStamp: timeStamp
  }
}

// Azure files for FSLogix
module azureFiles 'modules/azureFiles.bicep' = if (storageSolution == 'AzureFiles') {
  name: 'AzureFiles_${timeStamp}'
  scope: resourceGroup(resourceGroupStorage)
  params: {
    availability: availability
    azureBackupPrivateDnsZoneResourceId: azureBackupPrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    deploymentUserAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    deploymentVirtualMachineName: deploymentVirtualMachineName
    deploymentResourceGroupName: resourceGroupDeployment
    domainJoinUserPassword: contains(identitySolution, 'DomainServices') ? domainJoinUserPassword : ''
    domainJoinUserPrincipalName: contains(identitySolution, 'DomainServices') ? domainJoinUserPrincipalName : ''
    encryptionKeyVaultUri: encryptionKeyVaultUri
    encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts == 'MicrosoftManaged'
      ? ''
      : customerManagedKeys.outputs.userAssignedIdentityResourceId
    fileShares: fslogixFileShares
    fslogixEncryptionKeyNameConv: fslogixEncryptionKeyNameConv
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    hostPoolResourceId: hostPoolResourceId
    identitySolution: identitySolution
    increaseQuota: increaseQuota
    increaseQuotaApplicationInsightsName: increaseQuotaAppInsightsName
    increaseQuotaEncryptionKeyName: increaseQuotaEncryptionKeyName
    increaseQuotaFunctionAppName: increaseQuotaFunctionAppName
    increaseQuotaStorageAccountName: increaseQuotaStorageAccountName
    kerberosEncryptionType: kerberosEncryptionType
    keyManagementStorageAccounts: keyManagementStorageAccounts
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId
    ouPath: ouPath
    privateEndpoint: privateEndpoint
    privateEndpointLocation: privateEndpoint && !empty(privateEndpointSubnetResourceId)
      ? reference(split(privateEndpointSubnetResourceId, '/subnets/')[0], '2020-06-01', 'Full').location
      : ''
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    recoveryServices: recoveryServices
    recoveryServicesVaultName: recoveryServicesVaultName
    resourceGroupStorage: resourceGroupStorage
    serverFarmId: serverFarmId
    shardingOptions: fslogixShardOptions
    shareAdminGroups: fslogixAdminGroups
    shareSizeInGB: shareSizeInGB
    shareUserGroups: fslogixUserGroups
    storageAccountNamePrefix: storageAccountNamePrefix
    storageCount: storageCount
    storageIndex: storageIndex
    storageSku: storageSku
    storageSolution: storageSolution
    tags: tags
    timeStamp: timeStamp
    timeZone: timeZone
  }
}

output netAppVolumeResourceIds array = storageSolution == 'AzureNetAppFiles'
  ? azureNetAppFiles.outputs.volumeResourceIds
  : []
output storageAccountResourceIds array = storageSolution == 'AzureFiles'
  ? azureFiles.outputs.storageAccountResourceIds
  : []

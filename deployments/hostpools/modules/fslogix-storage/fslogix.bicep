targetScope = 'subscription'

param activeDirectoryConnection bool
param identitySolution string
param azureFilePrivateDnsZoneResourceId string
param deploymentSuffix string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param encryptionKeyVaultUri string
param fslogixAdminGroups array
param appUpdateUserAssignedIdentityResourceId string
param fslogixEncryptionKeyNameConv string
param fslogixFileShares array
param fslogixShardOptions string
param fslogixUserGroups array
param hostPoolResourceId string
param kerberosEncryptionType string
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
param resourceGroupDeployment string
param resourceGroupStorage string
param shareSizeInGB int
param smbServerLocation string
param storageAccountNamePrefix string
param storageCount int
param storageIndex int
param storageSku string
param fslogixStorageRedundancy string
param storageSolution string
param tags object
param encryptionUserAssignedIdentityResourceId string = ''
param permittedIPs array = []
param fslogixSoftDeleteRetentionDays int = 14
param recoveryServicesVaultResourceId string = ''
param fileSharePolicyName string = 'filesharepolicy'

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
    deploymentSuffix: deploymentSuffix
    permittedIPs: permittedIPs
    softDeleteRetentionDays: fslogixSoftDeleteRetentionDays
  }
}

// Register all Azure Files storage accounts and shares with the Recovery Services Vault for snapshot backup.
// Scoped to the vault's resource group so ARM child resource declarations resolve correctly.
module fslogixBackupRegistration '../operations/fslogixBackupItems.bicep' = if (storageSolution == 'AzureFiles' && !empty(recoveryServicesVaultResourceId)) {
  name: 'FSLogix-BackupItems-${deploymentSuffix}'
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

output encryptionUserAssignedIdentityResourceId string = encryptionUserAssignedIdentityResourceId
output netAppVolumeResourceIds array = storageSolution == 'AzureNetAppFiles'
  ? azureNetAppFiles!.outputs.volumeResourceIds
  : []
output storageAccountResourceIds array = storageSolution == 'AzureFiles'
  ? azureFiles!.outputs.storageAccountResourceIds
  : []

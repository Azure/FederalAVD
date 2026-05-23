targetScope = 'subscription'

param resourceGroupName string
param keyVaultResourceId string
param keyManagementType string
param keyExpirationInDays int
param location string
param tags object = {}
param deploymentSuffix string
param keyName string
param diskEncryptionSetName string

module cmk '../../../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = {
  name: 'Disk-CMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: keyVaultResourceId
    keyManagementType: keyManagementType
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: deploymentSuffix
    diskEncryptionConfigs: [
      {
        keyName: keyName
        diskEncryptionSetName: diskEncryptionSetName
        confidentialVMOSDiskEncryption: false
      }
    ]
  }
}

@description('Resource ID of the created DiskEncryptionSet.')
output diskEncryptionSetResourceId string = cmk.outputs.diskResults[0].diskEncryptionSetResourceId

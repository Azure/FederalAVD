targetScope = 'subscription'

param resourceGroupName string
param keyVaultResourceId string
param keyManagementType string
param keyExpirationInDays int
param location string
param tags object = {}
@description('Optional. Resource ID stamped as the cm-resource-parent tag on the key and Disk Encryption Set.')
param parentResourceId string = ''
param keyName string
param diskEncryptionSetName string

module cmk 'customerManagedKeys.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: keyVaultResourceId
    keyManagementType: keyManagementType
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    parentResourceId: parentResourceId
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

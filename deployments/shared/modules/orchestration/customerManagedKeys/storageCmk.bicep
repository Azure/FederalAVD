targetScope = 'subscription'

param resourceGroupName string
param keyVaultResourceId string
param keyManagementType string
param keyExpirationInDays int
param location string
param tags object = {}
@description('Optional. Resource ID stamped as the cm-resource-parent tag on keys and the encryption identity.')
param parentResourceId string = ''
param storageKeyNames array
param identityName string = ''

module cmk 'customerManagedKeys.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: keyVaultResourceId
    keyManagementType: keyManagementType
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    parentResourceId: parentResourceId
    keyNames: storageKeyNames
    identityName: identityName
  }
}

@description('Resource ID of the storage encryption user-assigned identity.')
output storageEncryptionIdentityResourceId string = cmk.outputs.identityResourceId

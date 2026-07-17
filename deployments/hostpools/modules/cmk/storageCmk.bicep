targetScope = 'subscription'

param resourceGroupName string
param keyVaultResourceId string
param keyManagementType string
param keyExpirationInDays int
param location string
param tags object = {}
param deploymentSuffix string
param storageKeyNames array
param identityName string = ''

module cmk '../../../sharedModules/customerManagedKeys/customerManagedKeys.bicep' = {
  name: 'Storage-CMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: keyVaultResourceId
    keyManagementType: keyManagementType
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: deploymentSuffix
    keyNames: storageKeyNames
    identityName: identityName
  }
}

@description('Resource ID of the storage encryption user-assigned identity.')
output storageEncryptionIdentityResourceId string = cmk.outputs.identityResourceId

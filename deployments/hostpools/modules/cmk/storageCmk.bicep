targetScope = 'subscription'

param resourceGroupName string
param keyVaultResourceId string
param keyManagementType string
param keyExpirationInDays int
param location string
param tags object = {}
param deploymentSuffix string
param storageKeyNameConv string
param storageCount int
param storageIndex int
param storageIdentityName string

var storageKeyNames = [for i in range(0, storageCount): replace(storageKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))]

module cmk '../../../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = {
  name: 'Storage-CMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: keyVaultResourceId
    keyManagementType: keyManagementType
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: deploymentSuffix
    storageKeyNames: storageKeyNames
    storageIdentityName: storageIdentityName
  }
}

@description('Resource ID of the shared storage encryption user-assigned identity.')
output storageIdentityResourceId string = cmk.outputs.storageIdentityResourceId

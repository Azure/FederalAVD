targetScope = 'subscription'

@description('Required. Resource group name in which to create the storage encryption identity and keys.')
param resourceGroupName string

@description('Required. Resource ID of the Key Vault holding the storage encryption keys.')
param keyVaultResourceId string

@description('Required. CMK type for storage encryption.')
@allowed(['CustomerManaged', 'CustomerManagedHSM'])
param keyManagementType string

@description('Required. Key expiration in days.')
param keyExpirationInDays int

@description('Required. Azure region for the user-assigned identity.')
param location string

@description('Optional. Tags to apply to resources.')
param tags object = {}

@description('Required. Deployment name suffix for uniqueness.')
param deploymentSuffix string

@description('Required. Key name convention with "##" placeholder for the zero-padded storage index.')
param storageKeyNameConv string

@description('Required. Number of storage accounts (and therefore keys) to create.')
param storageCount int

@description('Required. Starting index for storage key naming.')
param storageIndex int

@description('Required. Name of the user-assigned identity to create for storage CMK.')
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

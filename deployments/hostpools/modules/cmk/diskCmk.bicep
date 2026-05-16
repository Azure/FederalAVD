targetScope = 'subscription'

@description('Required. Resource group name in which to create the disk encryption set.')
param resourceGroupName string

@description('Required. Resource ID of the Key Vault holding the disk encryption key.')
param keyVaultResourceId string

@description('Required. CMK type for disk encryption.')
@allowed(['CustomerManaged', 'CustomerManagedHSM', 'PlatformManagedAndCustomerManaged', 'PlatformManagedAndCustomerManagedHSM'])
param keyManagementType string

@description('Required. Key expiration in days.')
param keyExpirationInDays int

@description('Required. Azure region for the DiskEncryptionSet.')
param location string

@description('Optional. Tags to apply to resources.')
param tags object = {}

@description('Required. Deployment name suffix for uniqueness.')
param deploymentSuffix string

@description('Required. Name of the Key Vault key to create.')
param keyName string

@description('Required. Name of the DiskEncryptionSet to create.')
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

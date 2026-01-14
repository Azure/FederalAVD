param keyVaultResourceId string
param location string
param privateEndpoint bool
param storageAccountKind string
param storageAccountName string
param storageAccountSku object
param encryptionKeyName string


var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultSubscriptionId = split(keyVaultResourceId, '/')[2]
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
  name: keyVaultName
}

// Update storage account with customer managed key encryption
// This resource updates the existing storage account created in the parent module
resource StorageAccountUpdate 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  sku: storageAccountSku
  kind: storageAccountKind
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowBlobPublicAccess: false
    allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    encryption: {
      keySource: 'Microsoft.KeyVault'
      keyvaultproperties: {
        keyname: encryptionKeyName
        keyvaulturi: keyVault.properties.vaultUri
      }
      requireInfrastructureEncryption: true     
    }
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
      defaultAction: privateEndpoint ? 'Deny' : 'Allow'
    }
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    sasPolicy: {
      expirationAction: 'Log'
      sasExpirationPeriod: '180.00:00:00'
    }
  }
}

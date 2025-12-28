param hostPoolResourceId string
param keyManagementStorageAccounts string
param keyVaultResourceId string
param keyExpirationInDays int = 180
param location string
param storageAccountKind string
param storageAccountName string
param storageAccountPrincipalId string
param storageAccountSku object
param encryptionKeyName string
param deploymentSuffix string

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultSubscriptionId = split(keyVaultResourceId, '/')[2]
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
  name: keyVaultName
}

// Create or update encryption key for function app storage account
module storageAccountEncryptionKey '../../resources/key-vault/vault/key/main.bicep' = {
  name: 'StorageEncryptionKey-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    attributesExportable: false
    keySize: 4096
    keyVaultName: keyVaultName
    kty: contains(keyManagementStorageAccounts, 'HSM') ? 'RSA-HSM' : 'RSA'
    name: encryptionKeyName
    rotationPolicy: {
      attributes: {
        expiryTime: 'P${string(keyExpirationInDays)}D'
      }
      lifetimeActions: [
        {
          action: {
            type: 'Notify'
          }
          trigger: {
            timeBeforeExpiry: 'P10D'
          }
        }
        {
          action: {
            type: 'Rotate'
          }
          trigger: {
            timeAfterCreate: 'P${string(keyExpirationInDays - 7)}D'
          }
        }
      ]
    }
    tags: { 'cm-resource-parent': hostPoolResourceId }
  }
}

// Assign Key Vault Crypto Service Encryption User role to the encryption identity
module roleAssignment_EncryptionKey '../../resources/key-vault/vault/key/rbac.bicep' = {
  name: 'RA-Encryption-Key-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: encryptionKeyName
    keyVaultName: keyVaultName
    principalId: storageAccountPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' //Key Vault Crypto Service Encryption User
  }
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
    encryption: {
      keySource: 'Microsoft.KeyVault'
      keyvaultproperties: {
        keyname: storageAccountEncryptionKey.outputs.name
        keyvaulturi: keyVault.properties.vaultUri
      }     
    }
  }
  dependsOn: [
    roleAssignment_EncryptionKey
  ]
}

param hostPoolResourceId string
param keyManagementStorageAccounts string
param keyVaultResourceId string
param keyExpirationInDays int = 180
param storageAccountName string
param encryptionKeyName string
param deploymentSuffix string

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultSubscriptionId = split(keyVaultResourceId, '/')[2]
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

// Create encryption key for function app storage account
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
    principalId: storageAccount.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' //Key Vault Crypto Service Encryption User
  }
}

resource StorageAccountUpdate 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccount.name
  properties: {
    encryption: {
      keySource: 'Microsoft.KeyVault'
      keyvaultproperties: {
        keyname: storageAccountEncryptionKey.outputs.name
        keyvaulturi: keyVault.properties.vaultUri
      }
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        table: {
          keyType: 'Account'
          enabled: true
        }
        queue: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
    }
  }
  dependsOn: [
    roleAssignment_EncryptionKey
  ]
}

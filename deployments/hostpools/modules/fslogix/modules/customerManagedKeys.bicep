param hostPoolResourceId string
param keyExpirationInDays int
param keyManagementStorageAccounts string
param fslogixEncryptionKeyNameConv string
param keyVaultResourceId string
param location string
param storageCount int
param storageIndex int
param increaseQuota bool
param increaseQuotaEncryptionKeyName string
param tags object
param timeStamp string
param userAssignedIdentityNameConv string

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]

module fslogixStorageAccountEncryptionKeys '../../../../sharedModules/resources/key-vault/vault/key/main.bicep' = [for i in range(0, storageCount) : {
  name: 'StorageEncryptionKey_${i + storageIndex}_${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    name: replace(fslogixEncryptionKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))
    attributesExportable: false
    keySize: 4096
    kty: contains(keyManagementStorageAccounts, 'HSM') ? 'RSA-HSM' : 'RSA'
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
}]

module increaseQuotaStorageAccountEncryptionKey '../../../../sharedModules/resources/key-vault/vault/key/main.bicep' = if (increaseQuota) {
  name: 'IncreaseQuotaEncryptionKey_${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    name: increaseQuotaEncryptionKeyName
    attributesExportable: false
    keySize: 4096
    kty: contains(keyManagementStorageAccounts, 'HSM') ? 'RSA-HSM' : 'RSA'
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

module userAssignedIdentity '../../../../sharedModules/resources/managed-identity/user-assigned-identity/main.bicep' = {
  name: 'UAI_Encryption_${timeStamp}'
  params: {
    location: location
    name: replace(userAssignedIdentityNameConv, 'TOKEN', 'storage-encryption')
    tags: union(
      { 'cm-resource-parent': hostPoolResourceId },
      tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
    )
  }
}

module roleAssignment_UAI_EncryptionUser_FSLogix '../../management/modules/key_RBAC.bicep' = [for i in range(0, storageCount): {
  name: 'RA_Encryption_User_FSLogix_${padLeft(i + storageIndex, 2, '0')}-${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: fslogixStorageAccountEncryptionKeys[i].outputs.name
    keyVaultName: keyVaultName
    principalId: userAssignedIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User
  }  
}]

module roleAssignment_UAI_EncryptionUser_increaseQuota '../../management/modules/key_RBAC.bicep' = if (increaseQuota) {
  name: 'RA_Encryption_User_IncreaseQuota-${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: increaseQuotaStorageAccountEncryptionKey.outputs.name
    keyVaultName: keyVaultName
    principalId: userAssignedIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User
  }  
}

output userAssignedIdentityResourceId string = userAssignedIdentity.outputs.resourceId

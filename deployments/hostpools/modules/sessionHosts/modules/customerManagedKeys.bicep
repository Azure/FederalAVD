param confidentialVMOSDiskEncryption bool
param confidentialVMOrchestratorObjectId string
param deploymentUserAssignedIdentityClientId string
param keyName string
param diskEncryptionSetNames object
param hostPoolResourceId string
param keyExpirationInDays int = 180
param keyManagementDisks string
param keyVaultResourceId string
param keyVaultUri string
param deploymentVirtualMachineName string
param resourceGroupDeployment string
param tags object
param timeStamp string

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]

var diskEncryptionSetEncryptionType = confidentialVMOSDiskEncryption
  ? 'ConfidentialVmEncryptedWithCustomerKey'
  : (!contains(keyManagementDisks, 'Platform')
      ? 'EncryptionAtRestWithCustomerKey'
      : 'EncryptionAtRestWithPlatformAndCustomerKeys')

module key '../../../../sharedModules/resources/key-vault/vault/key/main.bicep' = if (!confidentialVMOSDiskEncryption) {
  name: 'Encryption_Key_${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    attributesEnabled: true
    attributesExportable: false
    keySize: 4096
    keyVaultName: keyVaultName
    kty: contains(keyManagementDisks, 'HSM') ? 'RSA-HSM' : 'RSA'
    name: keyName
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

module confidentialVM_key '../../../../sharedModules/resources/compute/virtual-machine/runCommand/main.bicep' = if (confidentialVMOSDiskEncryption) {
  name: 'Set_EncryptionKey_ConfidentialVMOSDisk_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    name: 'Set_ConfidentialVM_Key_Disks'
    parameters: [
      {
        name: 'KeyName'
        value: keyName
      }
      {
        name: 'Tags'
        value: string({ 'cm-resource-parent': hostPoolResourceId })
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: deploymentUserAssignedIdentityClientId
      }
      {
        name: 'VaultUri'
        value: keyVaultUri
      }
    ]
    script: loadTextContent('../../../../../.common/scripts/Set-ConfidentialVMOSDiskEncryptionKey.ps1')
    treatFailureAsDeploymentFailure: true
    virtualMachineName: deploymentVirtualMachineName
  }
}

module roleAssignment_ConfVMOrchestrator_ReleaseUser '../../management/modules/key_RBAC.bicep' = if (confidentialVMOSDiskEncryption) {
  name: 'RoleAssignment_ConfVMOrchestrator_ReleaseUser_${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: keyName
    keyVaultName: keyVaultName
    principalId: confidentialVMOrchestratorObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: '08bbd89e-9f13-488c-ac41-acfcb10c90ab' // Key Vault Crypto Service Release User 
  }
  dependsOn: [
    confidentialVM_key
  ]
}

module diskEncryptionSet '../../../../sharedModules/resources/compute/disk-encryption-set/main.bicep' = {
  name: 'DiskEncryptionSet_${timeStamp}'
  params: {
    rotationToLatestKeyVersionEnabled: confidentialVMOSDiskEncryption ? false : true
    name: confidentialVMOSDiskEncryption
      ? diskEncryptionSetNames.confidentialVMs
      : (diskEncryptionSetEncryptionType == 'EncryptionAtRestWithCustomerKey'
          ? diskEncryptionSetNames.customerManaged
          : diskEncryptionSetNames.platformAndCustomerManaged)
    encryptionType: diskEncryptionSetEncryptionType
    keyName: keyName
    keyVaultResourceId: keyVaultResourceId
    systemAssignedIdentity: true
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Compute/diskEncryptionSets'] ?? {})
  }
  dependsOn: [
    key
    confidentialVM_key
  ]
}

module roleAssignment_DiskEncryptionSet_EncryptUser '../../management/modules/key_RBAC.bicep' = {
  name: 'RA_DiskEncryptionSet_CryptoServiceEncryptionUser_${timeStamp}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: keyName
    keyVaultName: keyVaultName
    principalId: diskEncryptionSet.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User
  }
}

output diskEncryptionSetResourceId string = diskEncryptionSet.outputs.resourceId

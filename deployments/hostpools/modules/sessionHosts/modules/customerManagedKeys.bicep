param confidentialVMOSDiskEncryption bool
param confidentialVMOrchestratorObjectId string
param deploymentUserAssignedIdentityClientId string
param keyName string
param location string
param diskEncryptionSetNames object
param hostPoolResourceId string
param keyExpirationInDays int = 180
param keyManagementDisks string
param keyVaultResourceId string
param keyVaultUri string
param deploymentVirtualMachineName string
param deploymentResourceGroupName string
param tags object
param deploymentSuffix string

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]
var roleKeyVaultCryptoUser = 'e147488a-f6f5-4113-8e2d-b22465e65bf6' //Key Vault Crypto Service Encryption User
var roleKeyVaultCryptoReleaseUser = '08bbd89e-9f13-488c-ac41-acfcb10c90ab' // Key Vault Crypto Service Release User 

var diskEncryptionSetEncryptionType = confidentialVMOSDiskEncryption
  ? 'ConfidentialVmEncryptedWithCustomerKey'
  : (!contains(keyManagementDisks, 'Platform')
      ? 'EncryptionAtRestWithCustomerKey'
      : 'EncryptionAtRestWithPlatformAndCustomerKeys')

module key '../../../../sharedModules/resources/key-vault/vault/key/main.bicep' = if (!confidentialVMOSDiskEncryption) {
  name: 'Encryption-Key-${deploymentSuffix}'
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
  name: 'Set-EncryptionKey-ConfidentialVMOSDisk-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    name: 'Set-ConfidentialVM-Key-Disks'
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
  name: 'RoleAssignment-ConfVMOrchestrator-ReleaseUser-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: keyName
    keyVaultName: keyVaultName
    principalId: confidentialVMOrchestratorObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleKeyVaultCryptoReleaseUser // Key Vault Crypto Service Release User 
  }
  dependsOn: [
    confidentialVM_key
  ]
}

module diskEncryptionSet '../../../../sharedModules/resources/compute/disk-encryption-set/main.bicep' = {
  name: 'DiskEncryptionSet-${deploymentSuffix}'
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
  name: 'RA-DiskEncryptionSet-CryptoServiceEncryptionUser-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyName: keyName
    keyVaultName: keyVaultName
    principalId: diskEncryptionSet.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleKeyVaultCryptoUser
  }
}

module getDiskEncryptionSetCryptoUserRoleAssignment '../../common/get-RoleAssignments.bicep' = {
  name: 'Get-DiskEncryptionSet-Crypto-User-RoleAssignment-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    location: location
    principalId: diskEncryptionSet.outputs.principalId
    resourceIds: ['${keyVaultResourceId}/keys/${keyName}']
    roleDefinitionId: roleKeyVaultCryptoUser
    runCommandName: 'Get-DiskEncryptionSetCryptoUserRoleAssignment' 
    userAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    virtualMachineName: deploymentVirtualMachineName
  }
  dependsOn: [
    roleAssignment_DiskEncryptionSet_EncryptUser
  ]
}

module getDiskEncryptionSetCryptoReleaseUserRoleAssignment '../../common/get-RoleAssignments.bicep' = if (confidentialVMOSDiskEncryption) {
  name: 'Get-DiskEncryptionSet-CryptoReleaseUser-RoleAssignment-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    location: location
    principalId: confidentialVMOrchestratorObjectId
    resourceIds: ['${keyVaultResourceId}/keys/${keyName}']
    roleDefinitionId: roleKeyVaultCryptoReleaseUser
    runCommandName: 'Get-DiskEncryptionSetCryptoReleaseUserRoleAssignment'
    userAssignedIdentityClientId: deploymentUserAssignedIdentityClientId
    virtualMachineName: deploymentVirtualMachineName
  }
  dependsOn: [
    roleAssignment_ConfVMOrchestrator_ReleaseUser
  ]
}

output diskEncryptionSetResourceId string = diskEncryptionSet.outputs.resourceId

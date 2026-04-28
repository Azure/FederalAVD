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

module key '../../../../../.common/bicepModules/keyVault/vaults/keys/deploy.bicep' = if (!confidentialVMOSDiskEncryption) {
  name: 'Encryption-Key-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    name: keyName
    attributesEnabled: true
    attributesExportable: false
    keySize: 4096
    kty: contains(keyManagementDisks, 'HSM') ? 'RSA-HSM' : 'RSA'
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

module confidentialVM_key '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (confidentialVMOSDiskEncryption) {
  name: 'Set-EncryptionKey-ConfidentialVMOSDisk-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Set-ConfidentialVM-Key-Disks'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Set-ConfidentialVMOSDiskEncryptionKey.ps1')
    parameters: [
      { name: 'KeyName', value: keyName }
      { name: 'Tags', value: string({ 'cm-resource-parent': hostPoolResourceId }) }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      { name: 'VaultUri', value: keyVaultUri }
    ]
    treatFailureAsDeploymentFailure: true
  }
}

module roleAssignment_ConfVMOrchestrator_ReleaseUser '../../../../../.common/bicepModules/keyVault/vaults/keys/roleAssignment.bicep' = if (confidentialVMOSDiskEncryption) {
  name: 'RoleAssignment-ConfVMOrchestrator-ReleaseUser-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    keyName: keyName
    assignments: [
      {
        principalId: confidentialVMOrchestratorObjectId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roleKeyVaultCryptoReleaseUser
      }
    ]
  }
  dependsOn: [
    confidentialVM_key
  ]
}

module diskEncryptionSet '../../../../../.common/bicepModules/compute/diskEncryptionSets/deploy.bicep' = {
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

module roleAssignment_DiskEncryptionSet_EncryptUser '../../../../../.common/bicepModules/keyVault/vaults/keys/roleAssignment.bicep' = {
  name: 'RA-DiskEncryptionSet-CryptoServiceEncryptionUser-${deploymentSuffix}'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    keyName: keyName
    assignments: [
      {
        principalId: diskEncryptionSet.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roleKeyVaultCryptoUser
      }
    ]
  }
}

module getDiskEncryptionSetCryptoUserRoleAssignment '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Get-DiskEncryptionSet-Crypto-User-RoleAssignment-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Get-DiskEncryptionSetCryptoUserRoleAssignment'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Get-RoleAssignments.ps1')
    treatFailureAsDeploymentFailure: false
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'ResourceIds', value: string(['${keyVaultResourceId}/keys/${keyName}']) }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      { name: 'PrincipalId', value: diskEncryptionSet.outputs.principalId }
      { name: 'RoleDefinitionId', value: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultCryptoUser) }
    ]
  }
  dependsOn: [
    roleAssignment_DiskEncryptionSet_EncryptUser
  ]
}

module getDiskEncryptionSetCryptoReleaseUserRoleAssignment '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (confidentialVMOSDiskEncryption) {
  name: 'Get-DiskEncryptionSet-CryptoReleaseUser-RoleAssignment-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Get-DiskEncryptionSetCryptoReleaseUserRoleAssignment'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Get-RoleAssignments.ps1')
    treatFailureAsDeploymentFailure: false
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'ResourceIds', value: string(['${keyVaultResourceId}/keys/${keyName}']) }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      { name: 'PrincipalId', value: confidentialVMOrchestratorObjectId }
      { name: 'RoleDefinitionId', value: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultCryptoReleaseUser) }
    ]
  }
  dependsOn: [
    roleAssignment_ConfVMOrchestrator_ReleaseUser
  ]
}

output diskEncryptionSetResourceId string = diskEncryptionSet.outputs.resourceId

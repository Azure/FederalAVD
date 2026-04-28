param deploymentVirtualMachineName string
param deploymentResourceGroupName string
param deploymentUserAssignedIdentityClientId string
param hostPoolResourceId string
param keyExpirationInDays int
param keyManagementStorageAccounts string
param fslogixEncryptionKeyNameConv string
param keyVaultResourceId string
param location string
param storageCount int
param storageIndex int
param tags object
param deploymentSuffix string
param userAssignedIdentityNameConv string

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]
var roleKeyVaultCryptoUser = 'e147488a-f6f5-4113-8e2d-b22465e65bf6'

// ─── Encryption keys ───────────────────────────────────────────────────────────
module kvEncryptionKeys '../../../../../.common/bicepModules/keyVault/vaults/keys/deploy.bicep' = [
  for i in range(0, storageCount): {
    name: 'StorageEncryptionKey-${i + storageIndex}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      name: replace(fslogixEncryptionKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))
      kty: contains(keyManagementStorageAccounts, 'HSM') ? 'RSA-HSM' : 'RSA'
      keySize: 4096
      attributesExportable: false
      rotationPolicy: {
        attributes: {
          expiryTime: 'P${string(keyExpirationInDays)}D'
        }
        lifetimeActions: [
          {
            action: { type: 'Notify' }
            trigger: { timeBeforeExpiry: 'P10D' }
          }
          {
            action: { type: 'Rotate' }
            trigger: { timeAfterCreate: 'P${string(keyExpirationInDays - 7)}D' }
          }
        ]
      }
      tags: { 'cm-resource-parent': hostPoolResourceId }
    }
  }
]

// ─── Encryption user-assigned identity ────────────────────────────────────────
module userAssignedIdentity '../../../../../.common/bicepModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  name: 'UAI-Encryption-${deploymentSuffix}'
  params: {
    name: replace(userAssignedIdentityNameConv, 'TOKEN', 'storage-encryption')
    location: location
    tags: union(
      { 'cm-resource-parent': hostPoolResourceId },
      tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
    )
  }
}

// ─── Key-level role assignment: Key Vault Crypto Service Encryption User ──────
module roleAssignment_UAI_EncryptionUser_FSLogix '../../../../../.common/bicepModules/keyVault/vaults/keys/roleAssignment.bicep' = [
  for i in range(0, storageCount): {
    name: 'RA-Encryption-User-FSLogix-${padLeft(i + storageIndex, 2, '0')}-${deploymentSuffix}'
    scope: resourceGroup(keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      keyName: kvEncryptionKeys[i].outputs.name
      assignments: [
        {
          principalId: userAssignedIdentity.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: roleKeyVaultCryptoUser
        }
      ]
    }
  }
]

// ─── Verify role assignments are in place before storage account creation ──────
// Key resource IDs are computed from params (no module output dependency needed)
var encryptionKeyResourceIds = [
  for i in range(0, storageCount): '${keyVaultResourceId}/keys/${replace(fslogixEncryptionKeyNameConv, '##', padLeft(i + storageIndex, 2, '0'))}'
]

module getRoleAssignments '../../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Get-UAI-KeyVault-Key-RoleAssignments-${deploymentSuffix}'
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Get-KeyVaultKeyRoleAssignmentsForUserAssignedIdentity'
    location: location
    script: loadTextContent('../../../../../.common/scripts/Get-RoleAssignments.ps1')
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'ResourceIds', value: string(encryptionKeyResourceIds) }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
      { name: 'PrincipalId', value: userAssignedIdentity.outputs.principalId }
      { name: 'RoleDefinitionId', value: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultCryptoUser) }
    ]
    treatFailureAsDeploymentFailure: false
  }
  dependsOn: [roleAssignment_UAI_EncryptionUser_FSLogix]
}

output userAssignedIdentityResourceId string = userAssignedIdentity.outputs.resourceId
output encryptionKeys array = [for i in range(0, storageCount): kvEncryptionKeys[i].outputs.resourceId]

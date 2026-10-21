metadata name = 'Storage encryption key orchestration'
metadata description = 'Creates keys in an existing Key Vault and a shared user-assigned encryption identity in an existing target resource group, granting that identity encryption access to every requested key.'

targetScope = 'subscription'

@description('Required. Name of the existing target resource group in the deployment subscription.')
param resourceGroupName string
@description('Required. Resource ID of the existing Key Vault that holds the encryption keys; may be in another resource group or subscription.')
param keyVaultResourceId string
@description('Required. Storage CMK mode; values containing HSM select RSA-HSM keys instead of RSA.')
param keyManagementType string
@description('Required. Key expiry interval in days; rotation is scheduled seven days before expiry.')
param keyExpirationInDays int
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Optional. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object = {}
@description('Optional. Resource ID stamped as the cm-resource-parent tag on keys and the encryption identity.')
param parentResourceId string = ''
@description('Required. Array of key name strings to create in the Key Vault and authorize for the shared encryption identity.')
param storageKeyNames array
@description('Optional. Name of the shared storage encryption user-assigned identity to create.')
param identityName string = ''

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultSubscriptionId = split(keyVaultResourceId, '/')[2]
var keyVaultResourceGroup = split(keyVaultResourceId, '/')[4]
var kty = contains(keyManagementType, 'HSM') ? 'RSA-HSM' : 'RSA'
var parentTag = !empty(parentResourceId) ? { 'cm-resource-parent': parentResourceId } : {}
var rotationPolicy = {
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

module storageKeys '../../resourceModules/keyVault/vaults/keys/deploy.bicep' = [
  for keyName in storageKeyNames: {
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      name: keyName
      kty: kty
      keySize: 4096
      attributesEnabled: true
      attributesExportable: false
      rotationPolicy: rotationPolicy
      tags: parentTag
    }
  }
]

module storageEncryptionIdentity '../../resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: identityName
    location: location
    tags: union(parentTag, tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {})
  }
}

module storageKeyRoleAssignments '../../resourceModules/keyVault/vaults/keys/roleAssignment.bicep' = [
  for (keyName, i) in storageKeyNames: {
    scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
    params: {
      keyVaultName: keyVaultName
      keyName: keyName
      assignments: [
        {
          principalId: storageEncryptionIdentity.outputs.principalId
          principalType: 'ServicePrincipal'
          roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
        }
      ]
    }
    dependsOn: [
      storageKeys[i]
    ]
  }
]

@description('Resource ID of the storage encryption user-assigned identity.')
output storageEncryptionIdentityResourceId string = storageEncryptionIdentity.outputs.resourceId

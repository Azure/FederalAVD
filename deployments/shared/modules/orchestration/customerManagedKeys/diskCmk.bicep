metadata name = 'Disk encryption key orchestration'
metadata description = 'Creates a Key Vault key, a disk encryption set in an existing target resource group, and key-scoped encryption permissions across subscription deployment scopes.'

targetScope = 'subscription'

@description('Required. Name of the existing target resource group in the deployment subscription.')
param resourceGroupName string
@description('Required. Resource ID of the existing Key Vault that holds the encryption keys; may be in another resource group or subscription.')
param keyVaultResourceId string
@description('Required. Encryption mode used to select RSA or RSA-HSM keys and single or double disk encryption.')
param keyManagementType string
@description('Required. Key expiry interval in days; rotation is scheduled seven days before expiry.')
param keyExpirationInDays int
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Optional. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object = {}
@description('Optional. Resource ID stamped as the cm-resource-parent tag on the key and Disk Encryption Set.')
param parentResourceId string = ''
@description('Required. Name of the encryption key to create in the existing Key Vault.')
param keyName string
@description('Required. Name of the disk encryption set to create in the target resource group.')
param diskEncryptionSetName string

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

module diskKey '../../resourceModules/keyVault/vaults/keys/deploy.bicep' = {
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

module diskEncryptionSet '../../resourceModules/compute/diskEncryptionSets/deploy.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: diskEncryptionSetName
    location: location
    keyVaultResourceId: keyVaultResourceId
    keyName: keyName
    encryptionType: !contains(keyManagementType, 'Platform')
      ? 'EncryptionAtRestWithCustomerKey'
      : 'EncryptionAtRestWithPlatformAndCustomerKeys'
    rotationToLatestKeyVersionEnabled: true
    systemAssignedIdentity: true
    tags: union(parentTag, tags[?'Microsoft.Compute/diskEncryptionSets'] ?? {})
  }
  dependsOn: [
    diskKey
  ]
}

module diskKeyRoleAssignment '../../resourceModules/keyVault/vaults/keys/roleAssignment.bicep' = {
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    keyName: keyName
    assignments: [
      {
        principalId: diskEncryptionSet.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
      }
    ]
  }
}

@description('Resource ID of the created DiskEncryptionSet.')
output diskEncryptionSetResourceId string = diskEncryptionSet.outputs.resourceId

@description('Required. The name of the disk encryption set that is being created.')
param name string

@description('Optional. Resource location.')
param location string = resourceGroup().location

@description('Required. Resource ID of the KeyVault containing the key or secret.')
param keyVaultResourceId string

@description('Required. Key URL (with version) pointing to a key or secret in KeyVault.')
param keyName string

@description('Optional. The version of the customer managed key to reference for encryption. If not provided, the latest key version is used.')
param keyVersion string = ''

@description('Optional. The type of key used to encrypt the data of the disk. For security reasons, it is recommended to set encryptionType to EncryptionAtRestWithPlatformAndCustomerKeys.')
@allowed([
  'ConfidentialVmEncryptedWithCustomerKey'
  'EncryptionAtRestWithCustomerKey'
  'EncryptionAtRestWithPlatformAndCustomerKeys'
])
param encryptionType string = 'EncryptionAtRestWithPlatformAndCustomerKeys'

@description('Optional. Multi-tenant application client ID to access key vault in a different tenant. Setting the value to "None" will clear the property.')
param federatedClientId string = 'None'

@description('Optional. Set this flag to true to enable auto-updating of this disk encryption set to the latest key version.')
param rotationToLatestKeyVersionEnabled bool = false

@description('Conditional. Enables system assigned managed identity on the resource. Required if userAssignedIdentities is empty.')
param systemAssignedIdentity bool = true

@description('Conditional. The ID(s) to assign to the resource. Required if systemAssignedIdentity is set to "false".')
param userAssignedIdentities object = {}

@description('Optional. Tags of the disk encryption resource.')
param tags object = {}

var identityType = systemAssignedIdentity ? (!empty(userAssignedIdentities) ? 'SystemAssigned,UserAssigned' : 'SystemAssigned') : 'UserAssigned'

var identity = {
  type: identityType
  userAssignedIdentities: !empty(userAssignedIdentities) ? userAssignedIdentities : null
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: last(split(keyVaultResourceId, '/'))!
  scope: resourceGroup(split(keyVaultResourceId, '/')[2], split(keyVaultResourceId, '/')[4])

  resource key 'keys@2023-07-01' existing = {
    name: keyName
  }
}

// Note: This is only enabled for user-assigned identities as the service's system-assigned identity isn't available during its initial deployment
module keyVaultPermissions '.bicep/nested_keyVaultPermissions.bicep' = [for (userAssignedIdentityId, index) in items(userAssignedIdentities): {
  name: 'DiskEncrSet-KVPermissions-${index}-${uniqueString(deployment().name, location)}'
  params: {
    location: location
    keyName: keyName
    keyVaultResourceId: keyVaultResourceId
    userAssignedIdentityResourceId: userAssignedIdentityId.key
    rbacAuthorizationEnabled: keyVault.properties.enableRbacAuthorization
  }
  scope: resourceGroup(split(keyVaultResourceId, '/')[2], split(keyVaultResourceId, '/')[4])
}]

resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = {
  name: name
  location: location
  tags: tags
  identity: identity
  properties: {
    activeKey: {
      sourceVault: {
        id: keyVaultResourceId
      }
      keyUrl: !empty(keyVersion) ? '${keyVault::key.properties.keyUri}/${keyVersion}' : keyVault::key.properties.keyUriWithVersion
    }
    encryptionType: encryptionType
    federatedClientId: federatedClientId
    rotationToLatestKeyVersionEnabled: rotationToLatestKeyVersionEnabled
  }
  dependsOn: [
    keyVaultPermissions
  ]
}

@description('The resource ID of the disk encryption set.')
output resourceId string = diskEncryptionSet.id

@description('The name of the disk encryption set.')
output name string = diskEncryptionSet.name

@description('The resource group the disk encryption set was deployed into.')
output resourceGroupName string = resourceGroup().name

@description('The principal ID of the disk encryption set.')
output principalId string = systemAssignedIdentity == true ? diskEncryptionSet.identity.principalId : ''

@description('The idenities of the disk encryption set.')
output identities object = diskEncryptionSet.identity

@description('The name of the key vault with the disk encryption key.')
output keyVaultName string = last(split(keyVaultResourceId, '/'))!

@description('The location the resource was deployed into.')
output location string = diskEncryptionSet.location

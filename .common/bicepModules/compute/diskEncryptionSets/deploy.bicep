param name string
param location string = resourceGroup().location
param tags object = {}

@description('Key Vault resource ID containing the encryption key.')
param keyVaultResourceId string

@description('Name of the key in the Key Vault.')
param keyName string

@description('Encryption type.')
@allowed([
  'EncryptionAtRestWithCustomerKey'
  'EncryptionAtRestWithPlatformAndCustomerKeys'
  'ConfidentialVmEncryptedWithCustomerKey'
])
param encryptionType string = 'EncryptionAtRestWithCustomerKey'

@description('Automatically rotate to the latest key version.')
param rotationToLatestKeyVersionEnabled bool = true

@description('Assign a system-assigned managed identity to the disk encryption set.')
param systemAssignedIdentity bool = true

var keyVaultName = last(split(keyVaultResourceId, '/'))
var keyVaultRG = split(keyVaultResourceId, '/')[4]
var keyVaultSub = split(keyVaultResourceId, '/')[2]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
  scope: resourceGroup(keyVaultSub, keyVaultRG)
}

resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-04-02' = {
  name: name
  location: location
  tags: tags
  identity: systemAssignedIdentity
    ? { type: 'SystemAssigned' }
    : { type: 'None' }
  properties: {
    encryptionType: encryptionType
    rotationToLatestKeyVersionEnabled: rotationToLatestKeyVersionEnabled
    activeKey: {
      keyUrl: '${keyVault.properties.vaultUri}keys/${keyName}'
      sourceVault: {
        id: keyVaultResourceId
      }
    }
  }
}

output resourceId string = diskEncryptionSet.id
output name string = diskEncryptionSet.name
output principalId string = systemAssignedIdentity ? diskEncryptionSet.identity.principalId : ''

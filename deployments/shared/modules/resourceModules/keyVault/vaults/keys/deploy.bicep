metadata name = 'Key Vault key'
metadata description = 'Creates or updates a key under an existing Key Vault in the deployment resource group, with optional rotation and release policies. Vault SKU and permissions must support the selected key type.'

@description('Required. Name of the existing parent Key Vault in the deployment resource group.')
param keyVaultName string
@description('Required. Name of the key Vault key within its parent resource.')
param name string

@description('Key type.')
@allowed(['RSA', 'RSA-HSM', 'EC', 'EC-HSM'])
param kty string = 'RSA'

@description('RSA key size in bits.')
@allowed([2048, 3072, 4096, 0])
param keySize int = 4096

@description('Whether the key is enabled for use.')
param attributesEnabled bool = true

@description('Whether the private key can be exported. Required for Confidential VM key release.')
param attributesExportable bool = false

@description('Optional. Permitted key operations. Defaults to all standard operations when empty.')
param keyOps array = []

@description('Optional. Key rotation policy.')
param rotationPolicy object = {}

@description('Optional. Key release policy. Required for Confidential VM encryption keys (exportable must also be true).')
param keyReleasePolicy object = {}

@description('Optional. Tags to apply to the key.')
param tags object = {}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource key 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: name
  tags: tags
  properties: {
    kty: kty
    keySize: keySize > 0 ? keySize : null
    keyOps: !empty(keyOps) ? keyOps : null
    attributes: {
      enabled: attributesEnabled
      exportable: attributesExportable
    }
    rotationPolicy: !empty(rotationPolicy) ? rotationPolicy : null
    release_policy: !empty(keyReleasePolicy) ? keyReleasePolicy : null
  }
}

@description('Resource ID of the key Vault key.')
output resourceId string = key.id
@description('Azure resource name of the key Vault key.')
output name string = key.name

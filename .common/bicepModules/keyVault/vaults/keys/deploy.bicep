param keyVaultName string
param name string

@description('Key type.')
@allowed(['RSA', 'RSA-HSM', 'EC', 'EC-HSM'])
param kty string = 'RSA'

@description('RSA key size in bits.')
@allowed([2048, 3072, 4096, 0])
param keySize int = 4096

@description('Whether the key is enabled for use.')
param attributesEnabled bool = true

@description('Whether the private key can be exported.')
param attributesExportable bool = false

@description('Optional. Key rotation policy.')
param rotationPolicy object = {}

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
    attributes: {
      enabled: attributesEnabled
      exportable: attributesExportable
    }
    rotationPolicy: !empty(rotationPolicy) ? rotationPolicy : null
  }
}

output resourceId string = key.id
output name string = key.name

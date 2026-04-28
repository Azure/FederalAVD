param keyVaultName string
param name string

@secure()
param value string

@description('Optional. Content type of the secret (e.g. "text/plain").')
param contentType string = ''

param tags object = {}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: name
  tags: tags
  properties: {
    value: value
    contentType: !empty(contentType) ? contentType : null
  }
}

output resourceId string = secret.id
output name string = secret.name

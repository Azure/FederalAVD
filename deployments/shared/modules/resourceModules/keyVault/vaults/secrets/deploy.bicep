metadata name = 'Key Vault secret'
metadata description = 'Writes a caller-supplied secure secret value to an existing Key Vault in the deployment resource group; returns the secret resource ID and name, not its value.'

@description('Required. Name of the existing parent Key Vault in the deployment resource group.')
param keyVaultName string
@description('Required. Name of the key Vault secret within its parent resource.')
param name string

@secure()
@description('Required. Secure secret value to write to the selected Key Vault.')
param value string

@description('Optional. Content type of the secret (e.g. "text/plain").')
param contentType string = ''

@description('Optional. Tags applied to the key Vault secret.')
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

@description('Resource ID of the key Vault secret.')
output resourceId string = secret.id
@description('Azure resource name of the key Vault secret.')
output name string = secret.name

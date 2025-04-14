param keyVaultName string
param principalId string
param principalType string
param keyName string
param roleDefinitionId string

resource keyVault 'Microsoft.KeyVault/vaults@2021-10-01' existing = {
  name: keyVaultName
  resource key 'keys@2021-10-01' existing = {
    name: keyName
  }
}

// =============== //
// Role Assignment //
// =============== //

resource keyVaultKeyRBAC 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault::key.id, principalId, roleDefinitionId)
  scope: keyVault::key
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalType: principalType
  }
}

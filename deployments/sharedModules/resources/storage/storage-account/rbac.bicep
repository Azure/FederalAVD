param principalIds array
param principalType string
param storageAccountResourceId string
param roleDefinitionId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: last(split(storageAccountResourceId, '/'))
} 

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = [for i in range(0, length(principalIds)): {
  name: guid(principalIds[i], roleDefinitionId, storageAccountResourceId)
  scope: storageAccount
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalIds[i]
    principalType: principalType
  }
}]

param principalId string
param principalType string
param templateSpecResourceId string
param roleDefinitionId string

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' existing = {
  name: last(split(templateSpecResourceId, '/'))
} 

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(principalId, roleDefinitionId, templateSpecResourceId)
  scope: templateSpec
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

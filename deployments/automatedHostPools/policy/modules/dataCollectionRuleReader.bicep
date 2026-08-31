@description('Required. Name of the existing Data Collection Rule.')
param dataCollectionRuleName string

@description('Required. Principal ID receiving Reader on the Data Collection Rule.')
param principalId string

@description('Required. Reader role definition ID.')
param readerRoleDefinitionId string

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: dataCollectionRuleName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataCollectionRule
  name: guid(dataCollectionRule.id, principalId, readerRoleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Azure Policy to read the Data Collection Rule linked from session host associations.'
  }
}

output resourceId string = roleAssignment.id

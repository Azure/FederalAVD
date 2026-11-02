metadata name = 'Data collection rule policy permissions'
metadata description = 'Grants Reader on an existing data collection rule in the deployment resource group to the supplied policy identity principal.'

@description('Required. Name of the existing data collection rule in the deployment resource group.')
param dataCollectionRuleName string
@description('Required. Principal object ID of the policy managed identity receiving the scoped role assignment.')
param principalId string

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: dataCollectionRuleName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataCollectionRule
  name: guid(dataCollectionRule.id, principalId, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Azure Policy to read the Data Collection Rule linked from session host associations.'
  }
}

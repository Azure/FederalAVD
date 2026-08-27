@description('Required. Name of the existing Data Collection Endpoint.')
param dataCollectionEndpointName string

@description('Required. Principal ID receiving Monitoring Contributor on the Data Collection Endpoint.')
param principalId string

@description('Required. Monitoring Contributor role definition ID.')
param monitoringContributorRoleDefinitionId string

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' existing = {
  name: dataCollectionEndpointName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataCollectionEndpoint
  name: guid(dataCollectionEndpoint.id, principalId, monitoringContributorRoleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Azure Policy to manage the Data Collection Endpoint linked from session host associations.'
  }
}

output resourceId string = roleAssignment.id

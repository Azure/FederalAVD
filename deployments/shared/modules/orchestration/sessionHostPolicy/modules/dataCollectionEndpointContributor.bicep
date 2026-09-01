param dataCollectionEndpointName string
param principalId string

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' existing = {
  name: dataCollectionEndpointName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataCollectionEndpoint
  name: guid(dataCollectionEndpoint.id, principalId, '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
    principalId: principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Azure Policy to manage the Data Collection Endpoint linked from session host associations.'
  }
}

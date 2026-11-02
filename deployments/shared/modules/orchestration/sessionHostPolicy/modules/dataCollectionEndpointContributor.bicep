metadata name = 'Data collection endpoint policy permissions'
metadata description = 'Grants Monitoring Contributor on an existing data collection endpoint in the deployment resource group to the supplied policy identity principal.'

@description('Required. Name of the data collection endpoint in the deployment resource group.')
param dataCollectionEndpointName string
@description('Required. Principal object ID of the policy managed identity receiving the scoped role assignment.')
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

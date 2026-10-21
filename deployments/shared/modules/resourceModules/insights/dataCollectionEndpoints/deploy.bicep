metadata name = 'Data collection endpoint'
metadata description = 'Deploys a regional Azure Monitor data collection endpoint with configurable public network access; rule associations and private links are managed separately.'

@description('Required. Name of the data collection endpoint to deploy.')
param name string
@description('Optional. Azure region for the data collection endpoint; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the data collection endpoint.')
param tags object = {}

@allowed(['Enabled', 'Disabled'])
@description('Optional. Public network access mode for this resource; private endpoints are configured separately.')
param publicNetworkAccess string = 'Enabled'

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: publicNetworkAccess
    }
  }
}

@description('Resource ID of the data collection endpoint.')
output resourceId string = dataCollectionEndpoint.id
@description('Azure resource name of the data collection endpoint.')
output name string = dataCollectionEndpoint.name

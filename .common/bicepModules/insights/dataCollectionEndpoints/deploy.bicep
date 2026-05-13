param name string
param location string = resourceGroup().location
param tags object = {}

@allowed(['Enabled', 'Disabled'])
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

output resourceId string = dataCollectionEndpoint.id
output name string = dataCollectionEndpoint.name

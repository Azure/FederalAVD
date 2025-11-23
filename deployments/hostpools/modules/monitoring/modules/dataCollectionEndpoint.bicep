param name string
param location string
param publicNetworkAccess string
param tags object

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: name
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: publicNetworkAccess
    }
  }
  tags: tags
}

output resourceId string = dce.id

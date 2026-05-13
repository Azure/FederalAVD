param name string
param location string = resourceGroup().location
param tags object = {}

@sys.description('Optional. Kind of the DCR. Windows or Linux for agent-based rules; blank for direct ingestion rules.')
@allowed(['Windows', 'Linux', ''])
param kind string = ''

@sys.description('Optional. Resource ID of the data collection endpoint to associate with this rule.')
param dataCollectionEndpointId string = ''

@sys.description('Optional. Data sources for the rule.')
param dataSources object = {}

@sys.description('Required. Destinations for collected data.')
param destinations object = {}

@sys.description('Required. Data flows connecting sources to destinations.')
param dataFlows array = []

@sys.description('Optional. Description of the rule.')
param description string = ''

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: name
  location: location
  tags: tags
  kind: !empty(kind) ? kind : null
  properties: {
    description: !empty(description) ? description : null
    dataCollectionEndpointId: !empty(dataCollectionEndpointId) ? dataCollectionEndpointId : null
    dataSources: !empty(dataSources) ? dataSources : null
    destinations: destinations
    dataFlows: dataFlows
  }
}

output resourceId string = dataCollectionRule.id
output name string = dataCollectionRule.name

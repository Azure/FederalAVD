metadata name = 'Data collection rule'
metadata description = 'Deploys an Azure Monitor data collection rule from caller-supplied sources, destinations and flows. Destination resources, optional endpoint and VM associations are managed separately.'

@sys.description('Required. Name of the data collection rule to deploy.')
param name string
@sys.description('Optional. Azure region for the data collection rule; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@sys.description('Optional. Tags applied to the data collection rule.')
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

@sys.description('Resource ID of the data collection rule.')
output resourceId string = dataCollectionRule.id
@sys.description('Azure resource name of the data collection rule.')
output name string = dataCollectionRule.name

param associationType string
param monitoringResourceId string
param virtualMachineName string

var dcrAssociationName = 'assoc-${uniqueString(virtualMachineName, monitoringResourceId)}'
var dceAssociationName = 'configurationAccessEndpoint'

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: virtualMachineName
}

resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (associationType == 'DataCollectionRule') {
  scope: virtualMachine
  name: dcrAssociationName
  properties: {
    dataCollectionRuleId: monitoringResourceId
  }
}

resource dataCollectionEndpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (associationType == 'DataCollectionEndpoint') {
  scope: virtualMachine
  name: dceAssociationName
  properties: {
    dataCollectionEndpointId: monitoringResourceId
  }
}

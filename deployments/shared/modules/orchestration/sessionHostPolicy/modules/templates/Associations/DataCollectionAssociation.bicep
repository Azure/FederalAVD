metadata name = 'Monitoring association remediation template'
metadata description = 'Creates a data collection rule or endpoint association on an existing VM in the deployment resource group according to the supplied association type.'

@description('Required. Association selector: DataCollectionRule or DataCollectionEndpoint.')
param associationType string
@description('Required. Resource ID of the existing data collection rule or endpoint selected by associationType.')
param monitoringResourceId string
@description('Required. Name of the existing VM in the deployment resource group.')
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

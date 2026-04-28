// Associates a Data Collection Rule (DCR) or Data Collection Endpoint (DCE) with a VM.
// Provide dataCollectionRuleId for DCR associations, or dataCollectionEndpointId for
// the configurationAccessEndpoint DCE association. Do not provide both in one call.

param virtualMachineName string

@description('Unique association name. Use a fixed name like "configurationAccessEndpoint" for DCE, or a descriptive name for DCR associations.')
param associationName string

param dataCollectionRuleId string = ''
param dataCollectionEndpointId string = ''

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: associationName
  scope: virtualMachine
  properties: {
    dataCollectionRuleId: !empty(dataCollectionRuleId) ? dataCollectionRuleId : null
    dataCollectionEndpointId: !empty(dataCollectionEndpointId) ? dataCollectionEndpointId : null
  }
}

output resourceId string = dcrAssociation.id
output name string = dcrAssociation.name

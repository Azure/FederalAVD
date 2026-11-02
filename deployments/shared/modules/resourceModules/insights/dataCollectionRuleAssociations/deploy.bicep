metadata name = 'VM data collection association'
metadata description = 'Associates an existing VM with either a data collection rule or a data collection endpoint. Supply exactly one target ID; this module does not install an agent.'

// Associates a Data Collection Rule (DCR) or Data Collection Endpoint (DCE) with a VM.
// Provide dataCollectionRuleId for DCR associations, or dataCollectionEndpointId for
// the configurationAccessEndpoint DCE association. Do not provide both in one call.

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string

@description('Unique association name. Use a fixed name like "configurationAccessEndpoint" for DCE, or a descriptive name for DCR associations.')
param associationName string

@description('Conditional. Resource ID of an existing data collection rule; supply this or dataCollectionEndpointId, not both.')
param dataCollectionRuleId string = ''
@description('Conditional. Resource ID of an existing data collection endpoint; supply this or dataCollectionRuleId, not both.')
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

@description('Resource ID of the VM data collection association.')
output resourceId string = dcrAssociation.id
@description('Azure resource name of the VM data collection association.')
output name string = dcrAssociation.name

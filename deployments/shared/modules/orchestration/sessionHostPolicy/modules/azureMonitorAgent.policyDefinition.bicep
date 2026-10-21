metadata name = 'Azure Monitor Agent policy definition'
metadata description = 'Defines a subscription DeployIfNotExists policy for Azure Monitor Agent on VMs with system-assigned identity; assignment and remediation permissions are owned by the caller.'

targetScope = 'subscription'

@description('Optional. Name of the subscription policy definition to create or update.')
param policyDefinitionName string = 'avdSessionHostAzureMonitorAgent-DeployIfNotExists'
var deploymentTemplate = loadJsonContent('templates/Extensions/AzureMonitorWindowsAgent.json')

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    displayName: 'Deploy Azure Monitor Agent on AVD session hosts'
    description: 'Deploys Azure Monitor Agent on AVD session host virtual machines that use a system-assigned managed identity.'
    mode: 'Indexed'
    metadata: { category: 'Azure Virtual Desktop', solution: 'AVD Session Host Governance', component: 'Monitoring', version: '1.0.0' }
    parameters: {
      effect: { type: 'String', allowedValues: ['DeployIfNotExists', 'Disabled'], defaultValue: 'DeployIfNotExists' }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Compute/virtualMachines' }
          { field: 'identity.type', contains: 'SystemAssigned' }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Compute/virtualMachines/extensions'
          name: '[concat(field(\'name\'), \'/AzureMonitorWindowsAgent\')]'
          evaluationDelay: 'AfterProvisioningSuccess'
          roleDefinitionIds: ['/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c']
          existenceCondition: {
            allOf: [
              { field: 'Microsoft.Compute/virtualMachines/extensions/type', equals: 'AzureMonitorWindowsAgent' }
              { field: 'Microsoft.Compute/virtualMachines/extensions/publisher', equals: 'Microsoft.Azure.Monitor' }
              { field: 'Microsoft.Compute/virtualMachines/extensions/provisioningState', equals: 'Succeeded' }
            ]
          }
          deployment: {
            properties: {
              mode: 'Incremental'
              parameters: {
                location: { value: '[field(\'location\')]' }
                virtualMachineName: { value: '[field(\'name\')]' }
              }
              template: deploymentTemplate
            }
          }
        }
      }
    }
  }
}

@description('Resource ID of the subscription policy definition created by this module.')
output policyDefinitionResourceId string = policyDefinition.id

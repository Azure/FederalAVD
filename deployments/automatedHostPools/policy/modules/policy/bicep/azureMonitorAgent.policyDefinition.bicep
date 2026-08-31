targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostAzureMonitorAgent-DeployIfNotExists'
param policyDefinitionDisplayName string = 'Deploy Azure Monitor Agent on automated AVD session hosts'
param policyDefinitionDescription string = 'Deploys Azure Monitor Agent on automated AVD session host virtual machines that use a system-assigned managed identity.'

var azureMonitorAgentTemplate = loadJsonContent('../templates/Extensions/AzureMonitorWindowsAgent.json')

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: policyDefinitionDescription
    displayName: policyDefinitionDisplayName
    mode: 'Indexed'
    metadata: {
      category: 'Azure Virtual Desktop'
      solution: 'Automated AVD Host Pools'
      component: 'Session Host Governance'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: [
          'DeployIfNotExists'
          'Disabled'
        ]
        defaultValue: 'DeployIfNotExists'
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Compute/virtualMachines'
          }
          {
            field: 'identity.type'
            contains: 'SystemAssigned'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Compute/virtualMachines/extensions'
          name: '[concat(field(\'name\'), \'/AzureMonitorWindowsAgent\')]'
          evaluationDelay: 'AfterProvisioningSuccess'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
          ]
          existenceCondition: {
            allOf: [
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/type'
                equals: 'AzureMonitorWindowsAgent'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/publisher'
                equals: 'Microsoft.Azure.Monitor'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/provisioningState'
                equals: 'Succeeded'
              }
            ]
          }
          deployment: {
            properties: {
              mode: 'Incremental'
              parameters: {
                location: {
                  value: '[field(\'location\')]'
                }
                virtualMachineName: {
                  value: '[field(\'name\')]'
                }
              }
              template: azureMonitorAgentTemplate
            }
          }
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

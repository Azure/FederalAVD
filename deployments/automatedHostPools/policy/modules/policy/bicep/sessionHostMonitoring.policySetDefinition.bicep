targetScope = 'subscription'

param policySetDefinitionName string = 'avdSessionHostMonitoring'
param azureMonitorAgentPolicyDefinitionResourceId string
param monitoringAssociationPolicyDefinitionResourceId string

resource policySetDefinition 'Microsoft.Authorization/policySetDefinitions@2024-05-01' = {
  name: policySetDefinitionName
  properties: {
    displayName: 'Configure monitoring on automated AVD session hosts'
    description: 'Groups custom monitoring policies that match the AVD service VM create request without relying on unavailable OS type fields.'
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
      dataCollectionRuleResourceId: {
        type: 'String'
      }
      dataCollectionEndpointResourceId: {
        type: 'String'
        defaultValue: ''
      }
      dataCollectionEndpointEffect: {
        type: 'String'
        allowedValues: [
          'DeployIfNotExists'
          'Disabled'
        ]
        defaultValue: 'Disabled'
      }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'deployAzureMonitorAgent'
        policyDefinitionId: azureMonitorAgentPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'associateDataCollectionRule'
        policyDefinitionId: monitoringAssociationPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
          associationType: {
            value: 'DataCollectionRule'
          }
          monitoringResourceId: {
            value: '[parameters(\'dataCollectionRuleResourceId\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'associateDataCollectionEndpoint'
        policyDefinitionId: monitoringAssociationPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'dataCollectionEndpointEffect\')]'
          }
          associationType: {
            value: 'DataCollectionEndpoint'
          }
          monitoringResourceId: {
            value: '[parameters(\'dataCollectionEndpointResourceId\')]'
          }
        }
      }
    ]
  }
}

output policySetDefinitionResourceId string = policySetDefinition.id

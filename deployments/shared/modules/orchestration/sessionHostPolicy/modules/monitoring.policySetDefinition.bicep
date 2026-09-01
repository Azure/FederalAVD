targetScope = 'subscription'

param policySetDefinitionName string = 'avdSessionHostMonitoring'
param azureMonitorAgentPolicyDefinitionResourceId string
param monitoringAssociationPolicyDefinitionResourceId string

resource policySetDefinition 'Microsoft.Authorization/policySetDefinitions@2024-05-01' = {
  name: policySetDefinitionName
  properties: {
    displayName: 'Configure monitoring on AVD session hosts'
    description: 'Enables Azure Monitor Agent and associates AVD session hosts with the selected DCR and optional DCE.'
    metadata: { category: 'Azure Virtual Desktop', solution: 'AVD Session Host Governance', component: 'Monitoring', version: '1.0.0' }
    parameters: {
      effect: { type: 'String', allowedValues: ['DeployIfNotExists', 'Disabled'], defaultValue: 'DeployIfNotExists' }
      dataCollectionRuleResourceId: { type: 'String' }
      dataCollectionEndpointResourceId: { type: 'String', defaultValue: '' }
      dataCollectionEndpointEffect: { type: 'String', allowedValues: ['DeployIfNotExists', 'Disabled'], defaultValue: 'Disabled' }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'deployAzureMonitorAgent'
        policyDefinitionId: azureMonitorAgentPolicyDefinitionResourceId
        parameters: { effect: { value: '[parameters(\'effect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'associateDataCollectionRule'
        policyDefinitionId: monitoringAssociationPolicyDefinitionResourceId
        parameters: {
          effect: { value: '[parameters(\'effect\')]' }
          associationType: { value: 'DataCollectionRule' }
          monitoringResourceId: { value: '[parameters(\'dataCollectionRuleResourceId\')]' }
        }
      }
      {
        policyDefinitionReferenceId: 'associateDataCollectionEndpoint'
        policyDefinitionId: monitoringAssociationPolicyDefinitionResourceId
        parameters: {
          effect: { value: '[parameters(\'dataCollectionEndpointEffect\')]' }
          associationType: { value: 'DataCollectionEndpoint' }
          monitoringResourceId: { value: '[parameters(\'dataCollectionEndpointResourceId\')]' }
        }
      }
    ]
  }
}

output policySetDefinitionResourceId string = policySetDefinition.id

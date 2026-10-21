metadata name = 'Session host monitoring initiative'
metadata description = 'Creates a subscription initiative combining supplied Agent and association definitions for Azure Monitor Agent, a data collection rule, and an optional data collection endpoint.'

targetScope = 'subscription'

@description('Optional. Name of the subscription monitoring initiative to create or update.')
param policySetDefinitionName string = 'avdSessionHostMonitoring'
@description('Required. Resource ID of the existing Azure Monitor Agent DeployIfNotExists definition included in the initiative.')
param azureMonitorAgentPolicyDefinitionResourceId string
@description('Required. Resource ID of the existing monitoring association definition reused for the DCR and optional DCE initiative members.')
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

@description('Resource ID of the subscription monitoring initiative created by this module.')
output policySetDefinitionResourceId string = policySetDefinition.id

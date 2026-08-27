targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostMonitoringAssociation-DeployIfNotExists'
param policyDefinitionDisplayName string = 'Associate automated AVD session hosts with a DCR or DCE'
param policyDefinitionDescription string = 'Associates automated AVD session host virtual machines with a selected Data Collection Rule or Data Collection Endpoint.'

var dataCollectionAssociationTemplate = loadJsonContent('../templates/Associations/DataCollectionAssociation.json')

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
      associationType: {
        type: 'String'
        allowedValues: [
          'DataCollectionRule'
          'DataCollectionEndpoint'
        ]
      }
      monitoringResourceId: {
        type: 'String'
      }
    }
    policyRule: {
      if: {
        field: 'type'
        equals: 'Microsoft.Compute/virtualMachines'
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Insights/dataCollectionRuleAssociations'
          evaluationDelay: 'AfterProvisioningSuccess'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa'
          ]
          existenceCondition: {
            anyOf: [
              {
                field: 'Microsoft.Insights/dataCollectionRuleAssociations/dataCollectionRuleId'
                equals: '[parameters(\'monitoringResourceId\')]'
              }
              {
                field: 'Microsoft.Insights/dataCollectionRuleAssociations/dataCollectionEndpointId'
                equals: '[parameters(\'monitoringResourceId\')]'
              }
            ]
          }
          deployment: {
            properties: {
              mode: 'Incremental'
              parameters: {
                associationType: {
                  value: '[parameters(\'associationType\')]'
                }
                monitoringResourceId: {
                  value: '[parameters(\'monitoringResourceId\')]'
                }
                virtualMachineName: {
                  value: '[field(\'name\')]'
                }
              }
              template: dataCollectionAssociationTemplate
            }
          }
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

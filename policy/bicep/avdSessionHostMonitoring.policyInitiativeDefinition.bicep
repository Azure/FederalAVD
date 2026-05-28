targetScope = 'subscription'

param timeStamp string = utcNow()

module policyDefinition_vmSystemAssignedIdentity 'virtualMachine-SystemAssignedIdentity.policyDefinition.bicep' = {
  name: 'policyDefinition-SystemAssignedIdentity-${timeStamp}'
}

resource initiativeDefinition 'Microsoft.Authorization/policySetDefinitions@2024-05-01' = {
  name: 'aVDSessionHostMonitoring'
  properties: {
    description: 'This initiative configures AVD Session Host Virtual Machines to enable AVD Insights and VM Insights Monitoring.'
    displayName: 'Configure AVD Session Host Monitoring'
    metadata: {
      category: 'Monitoring'
      version: '1.0.0'
    }
    parameters: {
      AVDInsightsDCRId: {
        type: 'string'
        metadata: {
          displayName: 'AVD Insights Data Collection Rule'
          description: 'The Resource ID of the AVD Insights Data Collection Rule'
          strongType: 'Microsoft.Insights/dataCollectionRules'
          portalReview: true
        }
      }
      DCEId: {
        type: 'string'
        metadata: {
          displayName: 'Data Collection Endpoint'
          description: 'The Resource Id of the Data Collection Endpoint.'
          strongType: 'Microsoft.Insights/dataCollectionEndpoints'
          portalReview: true
        }
      }
    }
    policyDefinitions: [
      {
        policyDefinitionId: policyDefinition_vmSystemAssignedIdentity.outputs.resourceId
        policyDefinitionReferenceId: 'SystemAssignedManagedIdentity'
      }
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'ca817e41-e85a-4783-bc7f-dc532d36235e')
        policyDefinitionReferenceId: 'DeployAzureMonitorAgent'
        parameters: {
          scopeToSupportedImages: {
            value: false
          }
        }
      }
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '244efd75-0d92-453c-b9a3-7d73ca36ed52')
        policyDefinitionReferenceId: 'AVDInsightsDataCollectionRule'
        parameters: {
          dcrResourceId: {
            value: '[parameters(\'AVDInsightsDCRId\')]'
          }
          resourceType: {
            value: 'Microsoft.Insights/dataCollectionRules'
          }
          scopeToSupportedImages: {
            value: false
          }
        }
      }      
      {
        policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '244efd75-0d92-453c-b9a3-7d73ca36ed52')
        policyDefinitionReferenceId: 'DataCollectionEndpoint'
        parameters: {
          dcrResourceId: {
            value: '[parameters(\'DCEId\')]'
          }
          resourceType: {
            value: 'Microsoft.Insights/dataCollectionEndpoints'
          }
          scopeToSupportedImages: {
            value: false
          }
        }
      }
    ]
  }
}


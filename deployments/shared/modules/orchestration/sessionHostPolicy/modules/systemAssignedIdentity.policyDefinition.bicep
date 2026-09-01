targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostSystemAssignedIdentity-Modify'

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    displayName: 'Configure system-assigned identity on AVD session hosts'
    description: 'Enables system-assigned managed identity on AVD session host virtual machines while preserving existing user-assigned identities.'
    mode: 'Indexed'
    metadata: {
      category: 'Azure Virtual Desktop'
      solution: 'AVD Session Host Governance'
      component: 'Monitoring'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Modify', 'Disabled']
        defaultValue: 'Modify'
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Compute/virtualMachines' }
          { field: 'identity.type', notContains: 'SystemAssigned' }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          conflictEffect: 'audit'
          roleDefinitionIds: ['/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c']
          operations: [
            {
              operation: 'AddOrReplace'
              field: 'identity.type'
              value: '[if(contains(field(\'identity.type\'), \'UserAssigned\'), concat(field(\'identity.type\'), \',SystemAssigned\'), \'SystemAssigned\')]'
            }
          ]
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

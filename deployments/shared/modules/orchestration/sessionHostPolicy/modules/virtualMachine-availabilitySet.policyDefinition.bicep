targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostAvailabilitySet-Modify'
param policyDefinitionDisplayName string = 'Assign AVD session hosts to managed availability sets'
param policyDefinitionDescription string = 'Assigns AVD session hosts to one managed Availability Set during virtual machine creation.'

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: policyDefinitionDescription
    displayName: policyDefinitionDisplayName
    mode: 'Indexed'
    metadata: {
      category: 'Azure Virtual Desktop'
      solution: 'AVD Session Host Governance'
      component: 'Creation Settings'
      version: '1.3.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Disabled'
      }
      availabilitySetResourceId: {
        type: 'String'
        defaultValue: ''
        metadata: {
          description: 'Resource ID of the managed Availability Set assigned to session host virtual machines.'
          strongType: 'Microsoft.Compute/availabilitySets'
        }
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
            field: 'Microsoft.Compute/virtualMachines/availabilitySet.id'
            notEquals: '[parameters(\'availabilitySetResourceId\')]'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          // Placement is creation-time only. Deny rather than silently creating a VM outside the requested set.
          conflictEffect: 'deny'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
          ]
          operations: [
            {
              operation: 'AddOrReplace'
              field: 'Microsoft.Compute/virtualMachines/availabilitySet.id'
              value: '[parameters(\'availabilitySetResourceId\')]'
            }
          ]
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

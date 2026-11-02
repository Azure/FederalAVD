metadata name = 'Accelerated networking policy definition'
metadata description = 'Defines a subscription Modify policy for the selected accelerated networking setting on NICs; its broad type predicate requires assignment within a dedicated session-host resource group.'

targetScope = 'subscription'

@description('Optional. Name of the subscription policy definition to create or update.')
param policyDefinitionName string = 'avdSessionHostAcceleratedNetworking-Modify'
@description('Optional. Display name stored on the subscription policy definition.')
param policyDefinitionDisplayName string = 'Configure accelerated networking on AVD session hosts'
@description('Optional. Description stored on the subscription policy definition; does not change its policy rule.')
param policyDefinitionDescription string = 'Enables or disables accelerated networking on network interfaces in the dedicated session host resource group.'

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
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Modify'
      }
      enableAcceleratedNetworking: {
        type: 'Boolean'
        defaultValue: true
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Network/networkInterfaces'
          }
          {
            field: 'Microsoft.Network/networkInterfaces/enableAcceleratedNetworking'
            notEquals: '[parameters(\'enableAcceleratedNetworking\')]'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          conflictEffect: 'audit'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
          ]
          operations: [
            {
              operation: 'AddOrReplace'
              field: 'Microsoft.Network/networkInterfaces/enableAcceleratedNetworking'
              value: '[parameters(\'enableAcceleratedNetworking\')]'
            }
          ]
        }
      }
    }
  }
}

@description('Resource ID of the subscription policy definition created by this module.')
output policyDefinitionResourceId string = policyDefinition.id

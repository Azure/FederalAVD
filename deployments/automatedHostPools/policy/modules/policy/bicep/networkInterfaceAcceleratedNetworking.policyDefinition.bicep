targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostAcceleratedNetworking-Modify'
param policyDefinitionDisplayName string = 'Configure accelerated networking on AVD session host network interfaces'
param policyDefinitionDescription string = 'Enables or disables accelerated networking on network interfaces in the dedicated session host resource group.'

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: policyDefinitionDescription
    displayName: policyDefinitionDisplayName
    mode: 'Indexed'
    metadata: {
      category: 'Azure Virtual Desktop'
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

output policyDefinitionResourceId string = policyDefinition.id

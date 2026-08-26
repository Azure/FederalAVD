targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostCompute-Modify'
param policyDefinitionDisplayName string = 'Configure AVD session host compute security settings'
param policyDefinitionDescription string = 'Configures encryption at host and an optional OS disk size during session host virtual machine creation or update.'

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
      encryptionAtHost: {
        type: 'Boolean'
        defaultValue: true
      }
      diskSizeGB: {
        type: 'Integer'
        defaultValue: 0
        metadata: {
          description: 'OS disk size in GB. Zero preserves the image default.'
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
            anyOf: [
              {
                field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'
                equals: 'Windows'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'
                exists: false
              }
            ]
          }
          {
            anyOf: [
              {
                field: 'Microsoft.Compute/virtualMachines/securityProfile.encryptionAtHost'
                notEquals: '[parameters(\'encryptionAtHost\')]'
              }
              {
                allOf: [
                  {
                    value: '[parameters(\'diskSizeGB\')]'
                    greater: 0
                  }
                  {
                    field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.diskSizeGB'
                    notEquals: '[parameters(\'diskSizeGB\')]'
                  }
                ]
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          conflictEffect: 'audit'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
          ]
          operations: [
            {
              operation: 'AddOrReplace'
              field: 'Microsoft.Compute/virtualMachines/securityProfile.encryptionAtHost'
              value: '[parameters(\'encryptionAtHost\')]'
            }
            {
              condition: '[greater(parameters(\'diskSizeGB\'), 0)]'
              operation: 'AddOrReplace'
              field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.diskSizeGB'
              value: '[parameters(\'diskSizeGB\')]'
            }
          ]
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

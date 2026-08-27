targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostManagedDiskNetworkAccess-Modify'
param policyDefinitionDisplayName string = 'Disable public access on AVD session host managed disks'
param policyDefinitionDescription string = 'Disables public network access and denies all network export access on managed disks in the session host resource group.'

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
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Compute/disks'
          }
          {
            anyOf: [
              {
                field: 'Microsoft.Compute/disks/publicNetworkAccess'
                notEquals: 'Disabled'
              }
              {
                field: 'Microsoft.Compute/disks/networkAccessPolicy'
                notEquals: 'DenyAll'
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
            '/providers/Microsoft.Authorization/roleDefinitions/60fc6e62-5479-42d4-8bf4-67625fcc2840'
          ]
          operations: [
            {
              operation: 'AddOrReplace'
              field: 'Microsoft.Compute/disks/publicNetworkAccess'
              value: 'Disabled'
            }
            {
              operation: 'AddOrReplace'
              field: 'Microsoft.Compute/disks/networkAccessPolicy'
              value: 'DenyAll'
            }
          ]
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

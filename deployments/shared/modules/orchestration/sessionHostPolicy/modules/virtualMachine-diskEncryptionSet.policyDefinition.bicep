metadata name = 'OS disk encryption set policy definition'
metadata description = 'Defines a subscription Modify policy assigning a supplied disk encryption set to VM OS disks; the caller owns assignment and permissions within the session-host resource group.'

targetScope = 'subscription'

@description('Optional. Name of the subscription policy definition to create or update.')
param policyDefinitionName string = 'avdSessionHostDiskEncryptionSet-Modify'
@description('Optional. Display name stored on the subscription policy definition.')
param policyDefinitionDisplayName string = 'Configure AVD session host Disk Encryption Set'
@description('Optional. Description stored on the subscription policy definition; does not change its policy rule.')
param policyDefinitionDescription string = 'Adds the specified Disk Encryption Set to Windows virtual machine OS disks during resource creation or update.'

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
      diskEncryptionSetResourceId: {
        type: 'String'
        metadata: {
          displayName: 'Disk Encryption Set'
          description: 'Resource ID of the existing Disk Encryption Set assigned to virtual machine OS disks.'
          strongType: 'Microsoft.Compute/diskEncryptionSets'
          assignPermissions: false
        }
      }
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Enable or disable Disk Encryption Set assignment.'
        }
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
            equals: 'Microsoft.Compute/virtualMachines'
          }
          {
            field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.managedDisk.diskEncryptionSet.id'
            notEquals: '[parameters(\'diskEncryptionSetResourceId\')]'
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
              field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.managedDisk.diskEncryptionSet.id'
              value: '[parameters(\'diskEncryptionSetResourceId\')]'
            }
          ]
        }
      }
    }
  }
}

@description('Resource ID of the subscription policy definition created by this module.')
output policyDefinitionResourceId string = policyDefinition.id

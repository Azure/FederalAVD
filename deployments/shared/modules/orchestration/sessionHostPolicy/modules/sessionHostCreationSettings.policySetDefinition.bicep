targetScope = 'subscription'

param policySetDefinitionName string = 'avdSessionHostCreationSettings'
param diskEncryptionSetPolicyDefinitionResourceId string
param sessionHostComputePolicyDefinitionResourceId string
param sessionHostSystemAssignedIdentityPolicyDefinitionResourceId string
param acceleratedNetworkingPolicyDefinitionResourceId string
param managedDiskNetworkAccessPolicyDefinitionResourceId string

resource policySetDefinition 'Microsoft.Authorization/policySetDefinitions@2024-05-01' = {
  name: policySetDefinitionName
  properties: {
    displayName: 'Configure AVD session host creation settings'
    description: 'Groups custom creation-time policies for settings that Session Host Configuration does not expose directly.'
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
      encryptionAtHost: {
        type: 'Boolean'
        defaultValue: true
      }
      diskSizeGB: {
        type: 'Integer'
        defaultValue: 0
      }
      enableAcceleratedNetworking: {
        type: 'Boolean'
        defaultValue: true
      }
      acceleratedNetworkingEffect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Disabled'
      }
      diskEncryptionSetEffect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Disabled'
      }
      diskEncryptionSetResourceId: {
        type: 'String'
        defaultValue: ''
      }
      managedDiskNetworkAccessEffect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Disabled'
      }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'configureSessionHostCompute'
        policyDefinitionId: sessionHostComputePolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
          encryptionAtHost: {
            value: '[parameters(\'encryptionAtHost\')]'
          }
          diskSizeGB: {
            value: '[parameters(\'diskSizeGB\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'configureDiskEncryptionSet'
        policyDefinitionId: diskEncryptionSetPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'diskEncryptionSetEffect\')]'
          }
          diskEncryptionSetResourceId: {
            value: '[parameters(\'diskEncryptionSetResourceId\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'configureSystemAssignedIdentity'
        policyDefinitionId: sessionHostSystemAssignedIdentityPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'configureAcceleratedNetworking'
        policyDefinitionId: acceleratedNetworkingPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'acceleratedNetworkingEffect\')]'
          }
          enableAcceleratedNetworking: {
            value: '[parameters(\'enableAcceleratedNetworking\')]'
          }
        }
      }
      {
        policyDefinitionReferenceId: 'configureManagedDiskNetworkAccess'
        policyDefinitionId: managedDiskNetworkAccessPolicyDefinitionResourceId
        parameters: {
          effect: {
            value: '[parameters(\'managedDiskNetworkAccessEffect\')]'
          }
        }
      }
    ]
  }
}

output policySetDefinitionResourceId string = policySetDefinition.id

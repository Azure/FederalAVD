targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostPrivateCustomization-DeployIfNotExists'
param policyDefinitionDisplayName string = 'Run a private customization on AVD session host virtual machines'
param policyDefinitionDescription string = 'Preserves existing VM identities, attaches a private artifact identity, and deploys a customization Run Command when the named command has not succeeded.'

var customizationTemplate = loadJsonContent('../templates/RunCommand/PrivateCustomization.json')

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: policyDefinitionDescription
    displayName: policyDefinitionDisplayName
    mode: 'All'
    metadata: {
      category: 'Azure Virtual Desktop'
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
        metadata: {
          displayName: 'Effect'
          description: 'Enable or disable private customization deployment.'
        }
      }
      artifactUri: {
        type: 'String'
        metadata: {
          displayName: 'Private artifact URI'
          description: 'HTTPS URI of the customization artifact in private Azure Blob Storage.'
        }
      }
      arguments: {
        type: 'String'
        defaultValue: ''
        metadata: {
          displayName: 'Arguments'
          description: 'Arguments passed to the customization artifact.'
        }
      }
      runCommandName: {
        type: 'String'
        metadata: {
          displayName: 'Run Command name'
        }
      }
      userAssignedIdentityResourceId: {
        type: 'String'
        metadata: {
          displayName: 'Private artifact identity'
          description: 'Resource ID of the user-assigned identity with read access to the artifact container.'
          strongType: 'Microsoft.ManagedIdentity/userAssignedIdentities'
          assignPermissions: false
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
            field: 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'
            equals: 'Windows'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Compute/virtualMachines/runCommands'
          name: '[concat(field(\'name\'), \'/\', parameters(\'runCommandName\'))]'
          evaluationDelay: 'AfterProvisioningSuccess'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
          ]
          existenceCondition: {
            field: 'Microsoft.Compute/virtualMachines/runCommands/provisioningState'
            equals: 'Succeeded'
          }
          deployment: {
            properties: {
              mode: 'Incremental'
              parameters: {
                artifactUri: {
                  value: '[parameters(\'artifactUri\')]'
                }
                arguments: {
                  value: '[parameters(\'arguments\')]'
                }
                location: {
                  value: '[field(\'location\')]'
                }
                runCommandName: {
                  value: '[parameters(\'runCommandName\')]'
                }
                userAssignedIdentityResourceId: {
                  value: '[parameters(\'userAssignedIdentityResourceId\')]'
                }
                virtualMachineName: {
                  value: '[field(\'name\')]'
                }
              }
              template: customizationTemplate
            }
          }
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id
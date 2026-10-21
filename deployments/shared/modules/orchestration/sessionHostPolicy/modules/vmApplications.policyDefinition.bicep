metadata name = 'VM Applications policy definition'
metadata description = 'Defines a subscription Modify policy maintaining the authoritative ordered Gallery application references, including latest-version matching, on VMs; the caller owns assignment and permissions.'

targetScope = 'subscription'

@description('Optional. Name of the subscription policy definition to create or update.')
param policyDefinitionName string = 'avdSessionHostVmApplication-Modify'
@description('Optional. Display name stored on the subscription policy definition.')
param policyDefinitionDisplayName string = 'Configure VM Applications on AVD session hosts'
@description('Optional. Description stored on the subscription policy definition; does not change its policy rule.')
param policyDefinitionDescription string = 'Configures an authoritative ordered list of Azure Compute Gallery application version references on AVD session host virtual machines during resource creation or update.'

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: policyDefinitionDescription
    displayName: policyDefinitionDisplayName
    mode: 'Indexed'
    metadata: {
      category: 'Azure Virtual Desktop'
      solution: 'AVD Session Host Governance'
      component: 'VM Applications'
      version: '1.0.1'
    }
    parameters: {
      galleryApplications: {
        type: 'Array'
        metadata: {
          displayName: 'Gallery applications'
          description: 'Authoritative ordered list of Gallery application version references assigned to each session host VM. References may select a specific version or use /versions/latest.'
        }
      }
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
            equals: 'Microsoft.Compute/virtualMachines'
          }
          {
            anyOf: [
              {
                count: {
                  field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*]'
                }
                notEquals: '[length(parameters(\'galleryApplications\'))]'
              }
              {
                count: {
                  value: '[parameters(\'galleryApplications\')]'
                  name: 'configuredApplication'
                  where: {
                    count: {
                      field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*]'
                      where: {
                        allOf: [
                          {
                            anyOf: [
                              {
                                field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*].packageReferenceId'
                                equals: '[current(\'configuredApplication\').packageReferenceId]'
                              }
                              {
                                allOf: [
                                  {
                                    value: '[endsWith(toLower(current(\'configuredApplication\').packageReferenceId), \'/versions/latest\')]'
                                    equals: true
                                  }
                                  {
                                    field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*].packageReferenceId'
                                    like: '[concat(substring(current(\'configuredApplication\').packageReferenceId, 0, add(lastIndexOf(toLower(current(\'configuredApplication\').packageReferenceId), \'/versions/\'), length(\'/versions/\'))), \'*\')]'
                                  }
                                ]
                              }
                            ]
                          }
                          {
                            field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*].order'
                            equals: '[current(\'configuredApplication\').order]'
                          }
                          {
                            field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*].treatFailureAsDeploymentFailure'
                            equals: '[current(\'configuredApplication\').treatFailureAsDeploymentFailure]'
                          }
                        ]
                      }
                    }
                    equals: 0
                  }
                }
                greater: 0
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
              field: 'Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications'
              value: '[parameters(\'galleryApplications\')]'
            }
          ]
        }
      }
    }
  }
}

@description('Resource ID of the subscription policy definition created by this module.')
output policyDefinitionResourceId string = policyDefinition.id

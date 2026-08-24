targetScope = 'subscription'

param policyDefinitionName string = 'avdSessionHostGuestAttestation-DeployIfNotExists'
param policyDefinitionDisplayName string = 'Deploy Guest Attestation on AVD session host virtual machines'
param policyDefinitionDescription string = 'Deploys the Guest Attestation extension required for Trusted Launch integrity monitoring.'

var guestAttestationTemplate = loadJsonContent('../templates/Extensions/GuestAttestation.json')

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
          {
            field: 'Microsoft.Compute/virtualMachines/securityProfile.securityType'
            in: [
              'TrustedLaunch'
              'ConfidentialVM'
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Compute/virtualMachines/extensions'
          name: '[concat(field(\'name\'), \'/GuestAttestation\')]'
          evaluationDelay: 'AfterProvisioningSuccess'
          roleDefinitionIds: [
            '/providers/Microsoft.Authorization/roleDefinitions/9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
          ]
          existenceCondition: {
            allOf: [
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/publisher'
                equals: 'Microsoft.Azure.Security.WindowsAttestation'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/type'
                equals: 'GuestAttestation'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/provisioningState'
                equals: 'Succeeded'
              }
            ]
          }
          deployment: {
            properties: {
              mode: 'Incremental'
              parameters: {
                location: {
                  value: '[field(\'location\')]'
                }
                virtualMachineName: {
                  value: '[field(\'name\')]'
                }
              }
              template: guestAttestationTemplate
            }
          }
        }
      }
    }
  }
}

output policyDefinitionResourceId string = policyDefinition.id

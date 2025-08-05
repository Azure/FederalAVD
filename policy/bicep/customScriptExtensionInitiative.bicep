targetScope = 'managementGroup'

param policyDefinitionNameAUAI string
param policyDefinitionDisplayNameAUAI string
param policyDefinitionDescriptionAUAI string = ''
param policyDefinitionNameCSE string
param policyDefinitionDisplayNameCSE string
param policyDefinitionDescriptionCSE string = ''
param subscriptionId string = ''
param policySetDefinitionName string
param policySetDefinitionDisplayName string
param policySetDefinitionDescription string = ''

module policyDefinition_AUAI '../../deployments/sharedModules/resources/authorization/policy-definition/main.bicep' = {
  name: 'dep-PolicyDefinition-AssignIdentity'
  params: {
    name: policyDefinitionNameAUAI
    mode: 'Indexed'
    displayName: policyDefinitionDisplayNameAUAI
    description: policyDefinitionDescriptionAUAI
    subscriptionId: subscriptionId
    parameters: loadJsonContent('../definitions/AssignUserAssignedIdentity.policyDefintion.json', 'parameters')
    policyRule: loadJsonContent('../definitions/AssignUserAssignedIdentity.policyDefintion.json', 'policyRule')
  }
}

module policyDefinition_CSE '../../deployments/sharedModules/resources/authorization/policy-definition/main.bicep' = {
  name: 'dep-PolicyDefinition-RunScripts'
  params: {
    name: policyDefinitionNameCSE
    mode: 'Indexed'
    displayName: policyDefinitionDisplayNameCSE
    description: policyDefinitionDescriptionCSE
    subscriptionId: subscriptionId
    parameters: loadJsonContent('../definitions/policy-CustomScriptExtension.json', 'parameters')
    policyRule: loadJsonContent('../definitions/policy-CustomScriptExtension.json', 'policyRule')
  }
}

module policySetDefinition '../../deployments/sharedModules/resources/authorization/policy-set-definition/main.bicep' = {
  name: 'dep-PolicySetDefinition'
  params: {
    name: policySetDefinitionName
    displayName: policySetDefinitionDisplayName
    description: policySetDefinitionDescription
    subscriptionId: subscriptionId
    parameters: {
      BlobContainerUri: {
        type: 'string'
        metadata: {
          displayName: 'Blob Container Uri'
          #disable-next-line no-hardcoded-env-urls
          description: 'This will be the Azure Storage Blob Container Url (e.g. "https://storageaccount.blob.core.windows.net/containername")'
        }
      }
      BlobNamesOrUris: {
        type: 'array'
        metadata: {
          displayName: 'Blob Names or File Uris'
          description: 'An array list of Blobs or full Uris to each file you wish to download via the Custom Script Extension in the order of download.'
          portalReview: true
        }
        defaultValue: []
      }
      ScriptToExecute: {
        type: 'string'
        metadata: {
          displayName: 'Script To Execute'
          description: 'The name of the PowerShell script to execute via the Custom Script Extension. This script must be in the list of Blob Names or File Uris'
          portalReview: true
        }
      }
      ScriptArguments: {
        type: 'string'
        metadata: {
          displayName: 'Script Arguments'
          description: 'PowerShell Script Arguments'
          portalReview: true
        }
        defaultValue: ''
      }
      UserAssignedIdentity: {
        type: 'string'
        metadata: {
          displayName: 'User-Assigned Identity'
          description: 'The Resource ID of the user assigned identity that has access to the artifactsUri.'
          strongType: 'Microsoft.ManagedIdentity/userAssignedIdentities'
          portalReview: true
        }
      }
    }
    policyDefinitions: [
      {
        policyDefinitionId: policyDefinition_AUAI.outputs.resourceId
        policyDefinitionReferenceId: policyDefinitionDisplayNameAUAI
        parameters: {
          userAssignedIdentityResourceId: {
            value: '[parameters(\'UserAssignedIdentity\')]'
          }
        }        
        groupNames: []
      }
      {
        policyDefinitionId: policyDefinition_CSE.outputs.resourceId
        policyDefinitionReferenceId: policyDefinitionDisplayNameCSE
        parameters: {
          artifactsUri: {
            value: '[parameters(\'BlobContainerUri\')]'
          }
          fileUris: {
            value: '[parameters(\'BlobNamesOrUris\')]'
          }
          scriptToRun: {
            value: '[parameters(\'ScriptToExecute\')]'
          }
          scriptArguments: {
            value: '[parameters(\'ScriptArguments\')]'
          }
          userAssignedIdentityResourceId: {
            value: '[parameters(\'UserAssignedIdentity\')]'
          }
        }
        groupNames: []
      }
    ]
  }
}

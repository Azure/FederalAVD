targetScope = 'subscription'

param policyDefinitionName string = 'virtualMachineSystemAssignedIdentity-Modify'
param policyDefinitionDisplayName string = 'Configure virtual machines with system-assigned managed identity'
param policyDefinitionDescription string = 'This policy will automatically enable the system-assigned managed identity on virtual machines.'

var policyJson = loadJsonContent('../definitions/AssignSystemAssignedIdentity.policyDefinition.json')

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2024-05-01' = {
  name: policyDefinitionName
  properties: {
    description: empty(policyDefinitionDescription) ? policyJson.description : policyDefinitionDescription
    displayName: empty(policyDefinitionDisplayName) ? policyJson.displayName : policyDefinitionDisplayName
    mode: policyJson.mode
    metadata: policyJson.metadata
    parameters: policyJson.parameters
    policyRule: policyJson.policyRule
  }
}

output resourceId string = policyDefinition.id

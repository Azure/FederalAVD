param location string
param runCommandName string
param principalId string
param resourceIds array
param roleDefinitionId string
param userAssignedIdentityClientId string = ''
param virtualMachineName string

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: virtualMachineName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: runCommandName
  parent: virtualMachine
  location: location
  properties: {
    asyncExecution: false
    parameters: [
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'ResourceIds'
        value: string(resourceIds)
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentityClientId
      }
      {
        name: 'PrincipalId'
        value: principalId
      }
      {
        name: 'RoleDefinitionId'
        value: subscriptionResourceId('microsoft.authorization/roleDefinitions', roleDefinitionId)
      }
    ]
    source: {
      script: loadTextContent('../../../../.common/scripts/Get-RoleAssignments.ps1')
    }
    timeoutInSeconds: 180
    treatFailureAsDeploymentFailure: true
  }
}

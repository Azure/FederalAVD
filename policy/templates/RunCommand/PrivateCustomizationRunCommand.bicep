param artifactUri string
param arguments string
param location string
param runCommandName string
param userAssignedIdentityResourceId string
param virtualMachineName string

var apiVersion = startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: virtualMachineName
}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(userAssignedIdentityResourceId, '/'))!
  scope: resourceGroup(
    split(userAssignedIdentityResourceId, '/')[2],
    split(userAssignedIdentityResourceId, '/')[4]
  )
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: virtualMachine
  name: runCommandName
  location: location
  properties: {
    parameters: [
      {
        name: 'APIVersion'
        value: apiVersion
      }
      {
        name: 'Arguments'
        value: arguments
      }
      {
        name: 'BlobStorageSuffix'
        value: 'blob.${environment().suffixes.storage}'
      }
      {
        name: 'Name'
        value: runCommandName
      }
      {
        name: 'Uri'
        value: artifactUri
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentity.properties.clientId
      }
    ]
    source: {
      script: loadTextContent('../../../deployments/shared/scripts/Invoke-Customization.ps1')
    }
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
@description('The arguments used with the Run Command Script')
param arguments string

@description('The Url of the script to download and Execute')
param artifacttUri string

@description('The location of the resource')
param location string

@description('The name of the RunCommand')
param runCommandName string

@description('The Resource Id of the User Assigned Identity used to access the Uri')
param userAssignedIdentityResourceId string

@description('The name of the Virtual Machine')
param virtualMachineName string

var apiVersion = startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: virtualMachineName
}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = if(!empty(userAssignedIdentityResourceId)) {
  name: last(split(userAssignedIdentityResourceId, '/'))
  scope: resourceGroup((split(userAssignedIdentityResourceId, '/'))[2], split(userAssignedIdentityResourceId, '/')[4])
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: runCommandName
  location: location
  parent: virtualMachine
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
        name: 'Uri'
        value: artifacttUri
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
        name: 'UserAssignedIdentityClientId'
        value: !empty(userAssignedIdentityResourceId) ? userAssignedIdentity.properties.clientId : ''
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Invoke-Customization.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

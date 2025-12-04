param appDisplayNamePrefix string
param location string
param userAssignedIdentityResourceId string
param virtualMachineName string

var graphEndpoint = environment().name == 'AzureCloud' ? 'https://graph.microsoft.com' : environment().name == 'AzureUSGovernment' ? 'https://graph.microsoft.us' : startsWith(environment().name, 'us') ? 'https://graph.${environment().suffixes.storage}' : 'https//dod-graph.microsoft.us'

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: last(split(userAssignedIdentityResourceId, '/'))
  scope: resourceGroup(split(userAssignedIdentityResourceId, '/')[2], split(userAssignedIdentityResourceId, '/')[4])
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: virtualMachineName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'Update-Storage-Account-Applications'
  location: location
  parent: virtualMachine
  properties: {
    asyncExecution: false
    parameters: [
      {
        name: 'AppDisplayNamePrefix'
        value: appDisplayNamePrefix
      }
      {
        name: 'ClientId'
        value: userAssignedIdentity.properties.clientId
      }
      {
        name: 'GraphEndpoint'
        value: graphEndpoint
      }
      {
        name: 'TenantId'
        value: subscription().tenantId
      }      
    ]
    source: {
      script: loadTextContent('../../../../../.common/scripts/Update-StorageAccountApplications.ps1')
    }
    timeoutInSeconds: 300
    treatFailureAsDeploymentFailure: true
  }
}

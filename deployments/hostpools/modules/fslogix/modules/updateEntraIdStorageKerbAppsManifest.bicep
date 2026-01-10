param appDisplayNamePrefix string
param enableCloudGroupSids bool
param location string
param privateEndpoint bool
param userAssignedIdentityResourceId string
param virtualMachineName string

// the graph endpoint varies for USGov and other US clouds. The DoD cloud uses a different endpoint. It will be handled within the function app code.
var graphEndpoint = environment().name == 'AzureUSGovernment' ? 'https://graph.microsoft.us' : startsWith(environment().name, 'us') ? 'https://graph.${environment().suffixes.storage}' : 'https://graph.microsoft.com'

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: last(split(userAssignedIdentityResourceId, '/'))
  scope: resourceGroup(split(userAssignedIdentityResourceId, '/')[2], split(userAssignedIdentityResourceId, '/')[4])
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: virtualMachineName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'Update-Storage-Account-Application-Manifest'
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
        name: 'PrivateEndpoint'
        value: string(privateEndpoint)
      }
      {
        name: 'EnableCloudGroupSids'
        value: string(enableCloudGroupSids)
      }      
    ]
    source: {
      script: loadTextContent('../../../../../.common/scripts/Update-StorageAccountApplicationManifest.ps1')
    }
    timeoutInSeconds: 300
    treatFailureAsDeploymentFailure: true
  }
}

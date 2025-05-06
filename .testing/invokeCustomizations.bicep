param artifactsContainerUri string
param customization object
param location string = resourceGroup().location
param userAssignedIdentityClientId string
param virtualMachineNames array

var apiVersion = environment().name == 'USNat' ? '2017-08-01' : '2018-02-01'

var customizer = {
  name: replace(customization.name, ' ', '-')
  uri: contains(customization.blobNameOrUri, '//:') ? customization.blobNameOrUri : '${artifactsContainerUri}/${customization.blobNameOrUri}' 
  arguments: customization.?arguments ?? ''
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-03-01' existing = [for (virtualMachineName, i) in virtualMachineNames: {
  name: virtualMachineName
}]

resource runCommands 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = [for (virtualMachineName, i) in virtualMachineNames: {
  name: customizer.name
  location: location
  parent: virtualMachine[i]
  properties: {
    parameters: [
      {
        name: 'APIVersion'
        value: apiVersion
      }
      {
        name: 'BlobStorageSuffix'
        value: 'blob.${environment().suffixes.storage}'
      }      
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentityClientId
      }    
      {
        name: 'Name'
        value: customizer.name
      }
      {
        name: 'Uri'
        value: customizer.uri
      }
      {
        name: 'Arguments'
        value: customizer.arguments
      }
    ]
    source: {
      script: loadTextContent('../.common/scripts/Invoke-Customization.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}]

param artifactsContainerUri string
param customizations array
param location string = resourceGroup().location
param userAssignedIdentityClientId string
param virtualMachineName string

var apiVersion = startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'

var customizers = [for customization in customizations: {
  name: replace(customization.name, ' ', '-')
  uri: startsWith(customization.blobNameOrUri, 'https://') || startsWith(customization.blobNameorUri, 'http://') ? customization.blobNameOrUri : '${artifactsContainerUri}/${customization.blobNameOrUri}' 
  arguments: customization.?arguments ?? ''
}]

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: virtualMachineName
}


@batchSize(1)
resource runCommands 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = [for customizer in customizers: {
  name: customizer.name
  location: location
  parent: virtualMachine
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
      script: loadTextContent('../../../../../.common/scripts/Invoke-Customization.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}]

param scriptsUserAssignedIdentityClientId string
param scripts array
param location string
param logsContainerUri string
param timeStamp string
param logsUserAssignedIdentityClientId string

param virtualMachineName string

var apiVersion = startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'

resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: virtualMachineName
}

@batchSize(1)
resource runCommands 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = [for script in scripts: {
  name: script.name
  location: location
  parent: virtualMachine
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logsContainerUri)
      ? null
      : {
          clientId: logsUserAssignedIdentityClientId
        }
    errorBlobUri: empty(logsContainerUri)
      ? null
      : '${logsContainerUri}${virtualMachineName}-${script.name}-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logsContainerUri)
      ? null
      : {
          clientId: logsUserAssignedIdentityClientId
        }
    outputBlobUri: empty(logsContainerUri)
      ? null
      : '${logsContainerUri}${virtualMachineName}-${script.name}-output-${timeStamp}.log'
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
        value: scriptsUserAssignedIdentityClientId
      }    
      {
        name: 'Name'
        value: script.name
      }
      {
        name: 'Uri'
        value: script.uri
      }
      {
        name: 'Arguments'
        value: script.arguments
      }
    ]
    source: {
      script: loadTextContent('Execute-Script.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}]

param scriptsUserAssignedIdentityClientId string
param scripts array
param location string
param logsContainerUri string
param timeStamp string
param logsUserAssignedIdentityClientId string

param virtualMachineName string

var apiVersion = startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'

resource existingVm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

@batchSize(1)
resource runCommands 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = [for script in scripts: {
  parent: existingVm
  name: script.name
  location: location
  properties: {
    source: {
      script: loadTextContent('../functions/Execute-Script.ps1')
    }
    parameters: [
      { name: 'APIVersion', value: apiVersion }
      { name: 'BlobStorageSuffix', value: 'blob.${environment().suffixes.storage}' }
      { name: 'UserAssignedIdentityClientId', value: scriptsUserAssignedIdentityClientId }
      { name: 'Name', value: script.name }
      { name: 'Uri', value: script.uri }
      { name: 'Arguments', value: script.arguments }
    ]
    outputBlobUri: empty(logsContainerUri) ? null : '${logsContainerUri}/${virtualMachineName}-${script.name}-output-${timeStamp}.log'
    errorBlobUri: empty(logsContainerUri) ? null : '${logsContainerUri}/${virtualMachineName}-${script.name}-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logsUserAssignedIdentityClientId) ? null : { clientId: logsUserAssignedIdentityClientId }
    errorBlobManagedIdentity: empty(logsUserAssignedIdentityClientId) ? null : { clientId: logsUserAssignedIdentityClientId }
  }
}]

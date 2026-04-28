param scriptsUserAssignedIdentityClientId string
param scripts array
param location string
param logsContainerUri string
param timeStamp string
param logsUserAssignedIdentityClientId string

param virtualMachineName string

var apiVersion = startsWith(environment().name, 'USN') ? '2017-08-01' : '2018-02-01'

@batchSize(1)
module runCommands '../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = [for script in scripts: {
  name: script.name
  params: {
    virtualMachineName: virtualMachineName
    location: location
    name: script.name
    script: loadTextContent('../functions/Execute-Script.ps1')
    outputBlobUri: empty(logsContainerUri) ? '' : '${logsContainerUri}/${virtualMachineName}-${script.name}-output-${timeStamp}.log'
    errorBlobUri: empty(logsContainerUri) ? '' : '${logsContainerUri}/${virtualMachineName}-${script.name}-error-${timeStamp}.log'
    outputBlobManagedIdentityClientId: logsUserAssignedIdentityClientId
    errorBlobManagedIdentityClientId: logsUserAssignedIdentityClientId
    parameters: [
      { name: 'APIVersion', value: apiVersion }
      { name: 'BlobStorageSuffix', value: 'blob.${environment().suffixes.storage}' }
      { name: 'UserAssignedIdentityClientId', value: scriptsUserAssignedIdentityClientId }
      { name: 'Name', value: script.name }
      { name: 'Uri', value: script.uri }
      { name: 'Arguments', value: script.arguments }
    ]
  }
}]

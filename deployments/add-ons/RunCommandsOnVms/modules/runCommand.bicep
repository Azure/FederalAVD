param location string
param vmName string
param runCommandName string
param logsUserAssignedIdentityClientId string
param logsContainerUri string
param parameters array
@secure()
param protectedParameter object = {}
param scriptContent string = ''
param scriptUri string = ''
param scriptsUserAssignedIdentityClientId string
param timeoutInSeconds int
param timeStamp string

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' existing = {
  name: vmName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: runCommandName
  parent: vm
  location: location
  properties: {
    errorBlobManagedIdentity: empty(logsUserAssignedIdentityClientId)
      ? null
      : {
          clientId: logsUserAssignedIdentityClientId
        }
    errorBlobUri: empty(logsContainerUri) || empty(logsUserAssignedIdentityClientId)
      ? null
      : '${logsContainerUri}/${vm}-${runCommandName}-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logsUserAssignedIdentityClientId)
      ? null
      : {
          clientId: logsUserAssignedIdentityClientId
        }
    outputBlobUri: empty(logsContainerUri) || empty(logsUserAssignedIdentityClientId)
      ? null
      : '${logsContainerUri}/${vm}-${runCommandName}-output-${timeStamp}.log'
    parameters: empty(parameters) ? null : parameters
    protectedParameters: empty(protectedParameter) ? null : [protectedParameter]
    source: {
      scriptUri: empty(scriptUri) ? null : scriptUri
      // Pass inline script content directly - no encoding needed
      // Run Command accepts up to 256KB of inline script content
      script: empty(scriptContent) ? null : scriptContent
      scriptUriManagedIdentity: empty(scriptsUserAssignedIdentityClientId)
        ? null
        : {
            clientId: scriptsUserAssignedIdentityClientId
          }
    }
    timeoutInSeconds: timeoutInSeconds == 5400 ? null : timeoutInSeconds
    treatFailureAsDeploymentFailure: true
  }
}

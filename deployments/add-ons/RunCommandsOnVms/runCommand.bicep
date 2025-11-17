param location string
param vmName string
param runCommandName string
param logsUserAssignedIdentityClientId string
param logsContainerUri string
param parameters array
@secure()
param protectedParameter object = {}
param base64ScriptContent string = ''
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
    protectedParameters: empty(base64ScriptContent)
      ? (empty(protectedParameter) ? null : [protectedParameter])
      : [
          {
            name: 'ScriptB64'
            value: base64ScriptContent
          }
        ]
    source: {
      scriptUri: empty(scriptUri) ? null : scriptUri
      script: empty(base64ScriptContent) ? null : loadTextContent('Execute-Base64Script.ps1')
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

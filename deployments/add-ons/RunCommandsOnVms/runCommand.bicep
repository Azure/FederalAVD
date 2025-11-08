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

// Prepare protected parameters, combine protectedParameters and base64 encoded script for inline script
var scriptContentAsParameter = empty(base64ScriptContent)
  ? {}
  : {
      name: 'ScriptB64'
      value: base64ScriptContent
    }

var protectedParametersForScriptContent = empty(protectedParameter)
  ? [scriptContentAsParameter]
  : union([scriptContentAsParameter], [
      {
        name: 'SecureParameter'
        value: protectedParameter
      }
    ])
// must build a single element array for parameters when using base64 script content
var parametersForScriptContent = [
  {
    name: 'Parameters'
    value: map(parameters, param => {
      name: param.name
      value: param.value
    })
  }
]

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
    parameters: empty(base64ScriptContent) ? (empty(parameters) ? null : parameters) : parametersForScriptContent
    protectedParameters: empty(base64ScriptContent)
      ? (empty(protectedParameter) ? null : [protectedParameter])
      : protectedParametersForScriptContent
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

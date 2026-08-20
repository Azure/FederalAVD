param virtualMachineName string
param name string
param location string = resourceGroup().location

@description('PowerShell script content to execute. Provide either script or scriptUri, not both.')
param script string = ''

@description('URI of a script to execute. Provide either script or scriptUri, not both.')
param scriptUri string = ''

@description('Client ID of the user-assigned managed identity used to access the script URI.')
param scriptUriManagedIdentityClientId string = ''

@description('Named parameters to pass to the script.')
param parameters array = []

@description('Named protected (secure) parameters to pass to the script.')
param protectedParameters array = []

@description('Maximum execution time in seconds. 0 = platform default (~1.5 hours).')
param timeoutInSeconds int = 0

@description('Run the command asynchronously (fire and forget).')
param asyncExecution bool = false

@description('Treat a non-zero exit code as a deployment failure.')
param treatFailureAsDeploymentFailure bool = false

@description('SAS URI or managed identity accessible blob URI to stream stdout to.')
param outputBlobUri string = ''

@description('SAS URI or managed identity accessible blob URI to stream stderr to.')
param errorBlobUri string = ''

@description('Client ID of the user-assigned managed identity used to access the output blob.')
param outputBlobManagedIdentityClientId string = ''

@description('Client ID of the user-assigned managed identity used to access the error blob.')
param errorBlobManagedIdentityClientId string = ''

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: virtualMachine
  name: name
  location: location
  properties: {
    source: {
      script: !empty(script) ? script : null
      scriptUri: !empty(scriptUri) ? scriptUri : null
      scriptUriManagedIdentity: !empty(scriptUriManagedIdentityClientId)
        ? { clientId: scriptUriManagedIdentityClientId }
        : null
    }
    parameters: !empty(parameters) ? parameters : null
    protectedParameters: !empty(protectedParameters) ? protectedParameters : null
    timeoutInSeconds: timeoutInSeconds > 0 ? timeoutInSeconds : null
    asyncExecution: asyncExecution
    treatFailureAsDeploymentFailure: treatFailureAsDeploymentFailure
    outputBlobUri: !empty(outputBlobUri) ? outputBlobUri : null
    errorBlobUri: !empty(errorBlobUri) ? errorBlobUri : null
    outputBlobManagedIdentity: !empty(outputBlobManagedIdentityClientId)
      ? { clientId: outputBlobManagedIdentityClientId }
      : null
    errorBlobManagedIdentity: !empty(errorBlobManagedIdentityClientId)
      ? { clientId: errorBlobManagedIdentityClientId }
      : null
  }
}

output resourceId string = runCommand.id
output name string = runCommand.name

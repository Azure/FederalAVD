metadata name = 'Virtual machine Run Command'
metadata description = 'Deploys a managed Run Command on an existing VM in the deployment resource group. Supply inline script or a reachable script URI and any required blob-access identity.'

import { runCommandParameterType } from '../../../types/customizationTypes.bicep'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Required. Name of the virtual machine Run Command to deploy.')
param name string
@description('Optional. Azure region for the virtual machine Run Command; defaults to the deployment resource group region.')
param location string = resourceGroup().location

@description('PowerShell script content to execute. Provide either script or scriptUri, not both.')
param script string = ''

@description('URI of a script to execute. Provide either script or scriptUri, not both.')
param scriptUri string = ''

@description('Client ID of the user-assigned managed identity used to access the script URI.')
param scriptUriManagedIdentityClientId string = ''

@description('Named parameters to pass to the script.')
param parameters runCommandParameterType[] = []

@description('Named protected (secure) parameters to pass to the script.')
param protectedParameters runCommandParameterType[] = []

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

@description('Resource ID of the virtual machine Run Command.')
output resourceId string = runCommand.id
@description('Azure resource name of the virtual machine Run Command.')
output name string = runCommand.name

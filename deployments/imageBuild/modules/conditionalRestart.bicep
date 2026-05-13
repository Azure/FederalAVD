param location string = resourceGroup().location
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param deploymentSuffix string = utcNow('yyyyMMddhhmm')
param userAssignedIdentityClientId string
param context string  // e.g. 'PostUpdates' or 'PostCleanup' — disambiguates resource names and blob URIs when called multiple times

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

var waitForRestartParameters = [
  {
    name: 'ResourceManagerUri'
    value: environment().resourceManager
  }
  {
    name: 'UserAssignedIdentityClientId'
    value: userAssignedIdentityClientId
  }
  {
    name: 'VmResourceId'
    value: imageVm.id
  }
]

resource cbsCheck 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'cbs-check-and-restart-${context}'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: false
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-CbsCheck-${context}-${deploymentSuffix}.log'
    source: {
      script: loadTextContent('../../../.common/scripts/Check-CbsAndRestart.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource waitForCbsRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'wait-for-cbs-restart-${context}'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-WaitForConditionalRestart-${context}-${deploymentSuffix}.log'
    parameters: waitForRestartParameters
    source: {
      script: loadTextContent('../../../.common/scripts/Wait-ForVmRestart.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    cbsCheck
  ]
}

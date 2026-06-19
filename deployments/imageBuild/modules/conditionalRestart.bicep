param location string = resourceGroup().location
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param deploymentSuffix string = utcNow('yyyyMMddhhmm')
param userAssignedIdentityClientId string
param context string  // e.g. 'PreBuild', 'PostUpdates', 'PostCleanup' — disambiguates resource names and blob URIs when called multiple times

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

// Name used as both the ARM resource name and passed to the orchestration script so it
// knows which run command's instanceView to read for the RESTART_REQUIRED=true/false signal.
var cbsCheckRunCommandName = 'cbs-check-${context}'

// Step 1 — runs on the IMAGE VM.
// Checks CBS registry paths and writes RESTART_REQUIRED=true/false to stdout.
// Does NOT issue a shutdown; the orchestration VM decides whether to restart.
resource cbsCheck 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: cbsCheckRunCommandName
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
      script: loadTextContent('../../../.common/scripts/Check-CbsState.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

// Step 2 — runs on the ORCHESTRATION VM.
// Reads the instanceView output of the CBS check run command via ARM REST API.
// If RESTART_REQUIRED=true, POSTs to the ARM restart API (a synchronous LRO that
// only completes once the VM is running and the agent responds) then waits 60s for
// the guest to fully initialize. No polling for power-state changes required.
// stdout is written to the same log blob container as the image VM scripts so the
// restart decision and polling progress appear alongside the rest of the build log.
resource conditionalRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'conditional-restart-${context}'
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
      : '${logBlobContainerUri}${imageVmName}-ConditionalRestart-${context}-${deploymentSuffix}.log'
    parameters: [
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentityClientId
      }
      {
        name: 'ImageVmResourceId'
        value: imageVm.id
      }
      {
        name: 'RunCommandName'
        value: cbsCheckRunCommandName
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Invoke-ConditionalRestart.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    cbsCheck
  ]
}

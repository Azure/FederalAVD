targetScope = 'resourceGroup'

@secure()
param adminPw string
param location string = resourceGroup().location
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param deploymentSuffix string = utcNow('yyMMddhhmm')
param userAssignedIdentityClientId string

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
  name: 'cbs-check-and-restart'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-CbsCheck-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-CbsCheck-output-${deploymentSuffix}.log'
    source: {
      script: loadTextContent('../../../.common/scripts/Check-CbsAndRestart.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource waitForCbsRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'wait-for-cbs-restart'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-WaitForCbsRestart-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-WaitForCbsRestart-output-${deploymentSuffix}.log'
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

resource sysprep 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'sysprep'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Sysprep-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Sysprep-output-${deploymentSuffix}.log'
    parameters: null
    protectedParameters: [
      {
        name: 'AdminUserPw'
        value: adminPw
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Invoke-Sysprep.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    waitForCbsRestart
  ]
}

resource generalizeVm 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'generalizeImageVm'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-GeneralizeVM-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-GeneralizeVM-output-${deploymentSuffix}.log'
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
            name: 'VmResourceId'
            value: imageVm.id
          }
        ]
    source: {
      script: loadTextContent('../../../.common/scripts/Generalize-Vm.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    sysprep
  ]
}

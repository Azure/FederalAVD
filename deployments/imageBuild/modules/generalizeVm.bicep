@secure()
param adminPw string
param location string = resourceGroup().location
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param buildTimestamp string = utcNow('yyyyMMddHHmmss')
param userAssignedIdentityClientId string

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

resource sysprep 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'sysprep'
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
      : '${logBlobContainerUri}${imageVmName}-Sysprep-${buildTimestamp}.log'
    protectedParameters: [
      {
        name: 'AdminPassword'
        value: adminPw
      }
    ]
    source: {
      script: loadTextContent('../scripts/Invoke-Sysprep.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource generalizeVm 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'generalizeImageVm'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
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
      script: loadTextContent('../scripts/Generalize-Vm.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    sysprep
  ]
}

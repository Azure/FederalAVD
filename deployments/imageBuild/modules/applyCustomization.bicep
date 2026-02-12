param customizer object
param location string
param imageVmName string
param orchestrationVmName string
param userAssignedIdentityClientId string
param logBlobContainerUri string
param deploymentSuffix string
param commonScriptParams array
param restartVMParameters array

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

resource application 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: customizer.name
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
      : '${logBlobContainerUri}${imageVmName}-${customizer.name}-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-${customizer.name}-output-${deploymentSuffix}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Uri'
        value: customizer.uri
      }
      {
        name: 'Name'
        value: customizer.name
      }
      {
        name: 'Arguments'
        value: customizer.arguments
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Invoke-Customization.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource restart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (customizer.restart) {
  name: '${customizer.name}-restart'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    parameters: restartVMParameters
    source: {
      script: loadTextContent('../../../../.common/scripts/Restart-Vm.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    application
  ]
}

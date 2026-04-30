param customization object
param location string
param imageVmName string
param orchestrationVmName string
param userAssignedIdentityClientId string
param logBlobContainerUri string
param deploymentSuffix string
param commonScriptParams array
param restartVMParameters array

var customizationScript = loadTextContent('../../../.common/scripts/Invoke-Customization.ps1')

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: orchestrationVmName
}

resource applyCustomization 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: customization.name
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
      : '${logBlobContainerUri}${imageVmName}-${customization.name}-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-${customization.name}-output-${deploymentSuffix}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Uri'
        value: customization.uri
      }
      {
        name: 'Name'
        value: customization.name
      }
      {
        name: 'Arguments'
        value: customization.arguments
      }
    ])
    source: {
      script: customizationScript
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource restart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (customization.restart) {
  name: '${customization.name}-restart'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    parameters: restartVMParameters
    source: {
      script: loadTextContent('../../../.common/scripts/Restart-Vm.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    applyCustomization
  ]
}

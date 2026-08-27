import { resolvedCustomizationType, runCommandParameterType } from '../../shared/modules/resourceModules/types/customizationTypes.bicep'

param customization resolvedCustomizationType
param location string
param imageVmName string
param orchestrationVmName string
param userAssignedIdentityClientId string
param logBlobContainerUri string
param buildTimestamp string
param commonScriptParams runCommandParameterType[]
param restartVMParameters runCommandParameterType[]

var customizationScript = loadTextContent('../../shared/scripts/Invoke-Customization.ps1')

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
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-${customization.name}-${buildTimestamp}.log'
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
      script: loadTextContent('../scripts/Restart-Vm.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    applyCustomization
  ]
}

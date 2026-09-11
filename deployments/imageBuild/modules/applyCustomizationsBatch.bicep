import { resolvedCustomizationType, runCommandParameterType } from '../../shared/modules/resourceModules/types/customizationTypes.bicep'

param customizations resolvedCustomizationType[]
param location string
param imageVmName string
param orchestrationVmName string
param userAssignedIdentityClientId string
param logBlobContainerUri string
param buildTimestamp string
param commonScriptParams runCommandParameterType[]
param restartVMParameters runCommandParameterType[]
param batchIndex int
param batchContext string
param resourceManagerUri string
param subscriptionId string
param resourceGroupName string

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

var removeRunCommandName = 'remove-${batchContext}-runCommands-batch-${batchIndex}'
var customizationDeploymentSuffix = batchContext == 'vdi' ? 'vdiCustomizer' : 'customizer'

@batchSize(1)
module applyCustomizations 'applyCustomization.bicep' = [
  for customization in customizations: {
    name: length('${customization.name}-${customizationDeploymentSuffix}') <= 64
      ? '${customization.name}-${customizationDeploymentSuffix}'
      : '${take(customization.name, batchContext == 'vdi' ? 36 : 39)}-${uniqueString(customization.name)}-${customizationDeploymentSuffix}'
    params: {
      customization: customization
      location: location
      imageVmName: imageVmName
      orchestrationVmName: orchestrationVmName
      userAssignedIdentityClientId: userAssignedIdentityClientId
      logBlobContainerUri: logBlobContainerUri
      buildTimestamp: buildTimestamp
      commonScriptParams: commonScriptParams
      restartVMParameters: restartVMParameters
    }
  }
]

resource removeRunCommands 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: orchestrationVm
  name: removeRunCommandName
  location: location
  properties: {
    asyncExecution: false
    parameters: [
      {
        name: 'ResourceManagerUri'
        value: resourceManagerUri
      }
      {
        name: 'SubscriptionId'
        value: subscriptionId
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentityClientId
      }
      {
        name: 'ImageVmName'
        value: imageVmName
      }
      {
        name: 'ImageBuildResourceGroup'
        value: resourceGroupName
      }
      {
        name: 'OrchestrationVmName'
        value: orchestrationVmName
      }
      {
        name: 'CurrentRunCommandName'
        value: removeRunCommandName
      }
    ]
    source: {
      script: loadTextContent('../scripts/Remove-ImageBuildRunCommands.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    applyCustomizations
  ]
}

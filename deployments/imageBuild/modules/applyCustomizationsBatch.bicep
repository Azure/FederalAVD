param customizations array
param location string
param imageVmName string
param orchestrationVmName string
param userAssignedIdentityClientId string
param logBlobContainerUri string
param deploymentSuffix string
param commonScriptParams array
param restartVMParameters array
param batchIndex int
param resourceManagerUri string
param subscriptionId string
param resourceGroupName string

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

@batchSize(1)
module applications 'applyCustomization.bicep' = [
  for customizer in customizations: {
    name: '${customizer.name}-${deploymentSuffix}'
    params: {
      customizer: customizer
      location: location
      imageVmName: imageVmName
      orchestrationVmName: orchestrationVmName
      userAssignedIdentityClientId: userAssignedIdentityClientId
      logBlobContainerUri: logBlobContainerUri
      deploymentSuffix: deploymentSuffix
      commonScriptParams: commonScriptParams
      restartVMParameters: restartVMParameters
    }
  }
]

resource removeRunCommands 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: orchestrationVm
  name: 'remove-custom-software-runCommands-batch-${batchIndex}'
  location: location
  properties: {
    asyncExecution: true
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
        name: 'VirtualMachineNames'
        value: string([imageVmName])
      }
      {
        name: 'virtualMachinesResourceGroup'
        value: resourceGroupName
      }
    ]
    source: {
      script: loadTextContent('../../../../.common/scripts/Remove-RunCommands.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    applications
  ]
}

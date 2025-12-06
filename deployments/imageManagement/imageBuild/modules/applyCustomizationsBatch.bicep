param customizations array
param location string
param imageVmName string
param orchestrationVmName string
param userAssignedIdentityClientId string
param logBlobContainerUri string
param deploymentSuffix string
param commonScriptParams array
param batchIndex int
param resourceManagerUri string
param subscriptionId string
param resourceGroupName string

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

@batchSize(1)
resource applications 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = [
  for customizer in customizations: {
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

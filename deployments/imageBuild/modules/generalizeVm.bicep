targetScope = 'resourceGroup'

@secure()
param adminPw string
param cloud string
param location string = resourceGroup().location
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param deploymentSuffix string = utcNow('yyMMddhhmm')
param userAssignedIdentityClientId string

var apiVersion = startsWith(cloud, 'usn') ? '2017-08-01' : '2018-02-01'

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
    parameters: empty(logBlobContainerUri)
      ? null
      : [
          {
            name: 'APIVersion'
            value: apiVersion
          }
          {
            name: 'LogBlobContainerUri'
            value: logBlobContainerUri
          }
          {
            name: 'UserAssignedIdentityClientId'
            value: userAssignedIdentityClientId
          }
        ]
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
      : '${logBlobContainerUri}${imageVmName}-Sysprep-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Sysprep-output-${deploymentSuffix}.log'
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

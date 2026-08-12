@secure()
param adminPw string
param location string = resourceGroup().location
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param deploymentSuffix string = utcNow('yyMMddhhmm')
param userAssignedIdentityClientId string

@description('Optional. When true, captures the sysprepped image as a WIM file using DISM and uploads it to blob storage before the VM is deallocated.')
param captureWim bool = false

@description('Conditional. Full blob URI for the WIM upload destination. Required when captureWim is true.')
param wimBlobUri string = ''

// Strip leading "blob." from the storage suffix to get the base cloud suffix
// (e.g. "core.windows.net" or "core.usgovcloudapi.net") used for IMDS token requests.
#disable-next-line BCP329
var envSuffix = substring(environment().suffixes.storage, 5, length(environment().suffixes.storage) - 5)

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
      : '${logBlobContainerUri}${imageVmName}-Sysprep-${deploymentSuffix}.log'
    protectedParameters: [
      {
        name: 'AdminPassword'
        value: adminPw
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Invoke-Sysprep.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

// Capture the sysprepped OS as a WIM file while the VM is still running after
// sysprep /quit. At this point the image is fully generalized (SIDs and
// machine-specific state removed) but not yet deallocated -- ideal for producing
// a deployment-ready WIM for MDT, SCCM, or Azure Local image deployment.
resource captureWimImage 'Microsoft.Compute/virtualMachines/runCommands@2023-07-01' = if (captureWim) {
  name: 'capture-wim'
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
      : '${logBlobContainerUri}${imageVmName}-WimCapture-${deploymentSuffix}.log'
    parameters: [
      {
        name: 'BlobStorageSuffix'
        value: envSuffix
      }
      {
        name: 'WimBlobUri'
        value: wimBlobUri
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: userAssignedIdentityClientId
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Invoke-WimCapture.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    sysprep
  ]
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
      script: loadTextContent('../../../.common/scripts/Generalize-Vm.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    sysprep
    captureWimImage
  ]
}

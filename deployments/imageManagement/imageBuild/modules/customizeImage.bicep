targetScope = 'resourceGroup'

param appsToRemove array
param cloud string
param downloads object
param downloadLatestMicrosoftContent bool
param location string = resourceGroup().location
param artifactsContainerUri string
param customizations array
param cleanupDesktop bool
param logBlobContainerUri string
param orchestrationVmName string
param imageVmName string
param installFsLogix bool
param installOneDrive bool
param installTeams bool
param installUpdates bool
param installVirtualDesktopOptimizationTool bool
param office365AppsToInstall array
param teamsCloudType string
param timeStamp string = utcNow('yyMMddhhmm')
param updateService string
param userAssignedIdentityClientId string
param vdiCustomizations array
param wsusServer string

var buildDir = 'c:\\BuildDir'

var apiVersion = startsWith(cloud, 'usn') ? '2017-08-01' : '2018-02-01'

var customizers = [
  for customization in customizations: {
    name: replace(customization.name, ' ', '-')
    uri: contains(customization.blobNameOrUri, '://')
      ? customization.blobNameOrUri
      : '${artifactsContainerUri}/${customization.blobNameOrUri}'
    arguments: customization.?arguments ?? ''
  }
]

var vdiCustomizers = [
  for customization in vdiCustomizations: {
    name: replace(customization.name, ' ', '-')
    uri: contains(customization.blobNameOrUri, '://')
      ? customization.blobNameOrUri
      : '${artifactsContainerUri}/${customization.blobNameOrUri}'
    arguments: customization.?arguments ?? ''
  }
]

var commonScriptParams = [
  {
    name: 'APIVersion'
    value: apiVersion
  }
  {
    name: 'BlobStorageSuffix'
    value: 'blob.${environment().suffixes.storage}'
  }
  {
    name: 'BuildDir'
    value: buildDir
  }
  {
    name: 'UserAssignedIdentityClientId'
    value: userAssignedIdentityClientId
  }
]

var restartVMParameters = [
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

var envSuffix = substring(environment().suffixes.storage, 5, length(environment().suffixes.storage) - 5)

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

resource createBuildDir 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'create-BuildDir'
  location: location
  parent: imageVm
  properties: {
    parameters: [
      {
        name: 'BuildDir'
        value: buildDir
      }
    ]
    source: {
      script: '''
        param(
          [string]$BuildDir
        )
        New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
  '''
    }
    treatFailureAsDeploymentFailure: true
  }
}

resource removeAppxPackages 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = if (!empty(appsToRemove)) {
  name: 'remove-appxPackages'
  location: location
  parent: imageVm
  properties: {
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Remove-AppxPackages-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Remove-AppxPackages-output-${timeStamp}.log'
    parameters: [
      {
        name: 'AppsToRemove'
        value: string(appsToRemove)
      }
    ]
    source: {
      script: loadTextContent('../../../../.common/scripts/Remove-AppXPackages.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

@batchSize(1)
resource applications 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = [
  for customizer in customizers: {
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
        : '${logBlobContainerUri}${imageVmName}-${customizer.name}-error-${timeStamp}.log'
      outputBlobManagedIdentity: empty(logBlobContainerUri)
        ? null
        : {
            clientId: userAssignedIdentityClientId
          }
      outputBlobUri: empty(logBlobContainerUri)
        ? null
        : '${logBlobContainerUri}${imageVmName}-${customizer.name}-output-${timeStamp}.log'
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
    dependsOn: [
      createBuildDir
      removeAppxPackages
    ]
  }
]

resource firstImageVmRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'restart-vm-1'
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
    createBuildDir
    removeAppxPackages
    applications
  ]
}

resource fslogix 'Microsoft.Compute/virtualMachines/runCommands@2023-07-01' = if (installFsLogix) {
  name: 'fslogix'
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
      : '${logBlobContainerUri}${imageVmName}-FSLogix-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-FSLogix-output-${timeStamp}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Name'
        value: 'FSLogix'
      }
      {
        name: 'Uri'
        value: !startsWith(cloud, 'us') && (downloadLatestMicrosoftContent || empty(artifactsContainerUri))
          ? downloads.FSLogix.DownloadUrl
          : '${artifactsContainerUri}/${downloads.FSLogix.DestinationFileName}'
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Install-FSLogix.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    firstImageVmRestart
  ]
}

resource office 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (!empty(office365AppsToInstall)) {
  name: 'm365Apps'
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
      : '${logBlobContainerUri}${imageVmName}-Office-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Office-output-${timeStamp}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Environment'
        value: cloud
      }
      {
        name: 'AppsToInstall'
        value: string(office365AppsToInstall)
      }
      {
        name: 'Name'
        value: 'Office-365-ProPlus'
      }
      {
        name: 'Uri'
        value: downloadLatestMicrosoftContent || empty(artifactsContainerUri)
          ? replace(downloads.Office365DeploymentTool.DownloadUrl, 'ENVSUFFIX', envSuffix)
          : '${artifactsContainerUri}/${downloads.Office365DeploymentTool.DestinationFileName}'
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Install-M365Applications.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    fslogix
    firstImageVmRestart
  ]
}

resource onedrive 'Microsoft.Compute/virtualMachines/runCommands@2023-07-01' = if (installOneDrive) {
  name: 'onedrive'
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
      : '${logBlobContainerUri}${imageVmName}-OneDrive-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-OneDrive-output-${timeStamp}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Name'
        value: 'OneDrive'
      }
      {
        name: 'Uri'
        value: downloadLatestMicrosoftContent || empty(artifactsContainerUri)
          ? replace(downloads.OneDrive.DownloadUrl, 'ENVSUFFIX', envSuffix)
          : '${artifactsContainerUri}/${downloads.OneDrive.DestinationFileName}'
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Install-OneDrive.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    firstImageVmRestart
    fslogix
    office
  ]
}

var teamsUris = !startsWith(cloud, 'us')
  ? downloadLatestMicrosoftContent || empty(artifactsContainerUri)
      ? [
          downloads.TeamsBootstrapper.DownloadUrl
          downloads.Teams64BitMSIX.DownloadUrl
          downloads.WebView2RunTime.DownloadUrl
          downloads.VisualStudioRedistributables.DownloadUrl
          downloads.RemoteDesktopWebRTCRedirectorService.DownloadUrl
        ]
      : [
          '${artifactsContainerUri}/${downloads.TeamsBootstrapper.DestinationFileName}'
          '${artifactsContainerUri}/${downloads.Teams64BitMSIX.DestinationFileName}'
          '${artifactsContainerUri}/${downloads.WebView2RunTime.DestinationFileName}'
          '${artifactsContainerUri}/${downloads.VisualStudioRedistributables.DestinationFileName}'
          '${artifactsContainerUri}/${downloads.RemoteDesktopWebRTCRedirectorService.DestinationFileName}'
        ]
  : empty(artifactsContainerUri)
      ? [
          replace(downloads.TeamsBootstrapper.DownloadUrl, 'ENVSUFFIX', envSuffix)
          replace(downloads.Teams64BitMSIX.DownloadUrl, 'ENVSUFFIX', envSuffix)
        ]
      : downloadLatestMicrosoftContent
          ? [
              replace(downloads.TeamsBootstrapper.DownloadUrl, 'ENVSUFFIX', envSuffix)
              replace(downloads.Teams64BitMSIX.DownloadUrl, 'ENVSUFFIX', envSuffix)
              '${artifactsContainerUri}/${downloads.WebView2RunTime.DestinationFileName}'
              '${artifactsContainerUri}/${downloads.VisualStudioRedistributables.DestinationFileName}'
              '${artifactsContainerUri}/${downloads.RemoteDesktopWebRTCRedirectorService.DestinationFileName}'
            ]
          : [
              '${artifactsContainerUri}/${downloads.TeamsBootstrapper.DestinationFileName}'
              '${artifactsContainerUri}/${downloads.Teams64BitMSIX.DestinationFileName}'
              '${artifactsContainerUri}/${downloads.WebView2RunTime.DestinationFileName}'
              '${artifactsContainerUri}/${downloads.VisualStudioRedistributables.DestinationFileName}'
              '${artifactsContainerUri}/${downloads.RemoteDesktopWebRTCRedirectorService.DestinationFileName}'
            ]
var teamsDestFileNames = length(teamsUris) == 2
  ? [
      downloads.TeamsBootstrapper.DestinationFileName
      downloads.Teams64BitMSIX.DestinationFileName
    ]
  : [
      downloads.TeamsBootstrapper.DestinationFileName
      downloads.Teams64BitMSIX.DestinationFileName
      downloads.WebView2RunTime.DestinationFileName
      downloads.VisualStudioRedistributables.DestinationFileName
      downloads.RemoteDesktopWebRTCRedirectorService.DestinationFileName
    ]

resource teams 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installTeams) {
  name: 'teams'
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
      : '${logBlobContainerUri}${imageVmName}-Teams-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Teams-output-${timeStamp}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Name'
        value: 'Teams'
      }
      {
        name: 'Uris'
        value: string(teamsUris)
      }
      {
        name: 'DestFileNames'
        value: string(teamsDestFileNames)
      }
      {
        name: 'TeamsCloudType'
        value: teamsCloudType
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Install-Teams.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    firstImageVmRestart
    fslogix
    office
    onedrive
  ]
}

resource secondImageVmRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installFsLogix || !empty(office365AppsToInstall) || installOneDrive || installTeams) {
  name: 'restart-vm-2'
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
    fslogix
    office
    onedrive
    teams
  ]
}

resource microsoftUpdates 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installUpdates) {
  name: 'microsoft-updates'
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
      : '${logBlobContainerUri}${imageVmName}-Install-Updates-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Install-Updates-output-${timeStamp}.log'
    parameters: updateService == 'WSUS'
      ? [
          {
            name: 'Service'
            value: updateService
          }
          {
            name: 'WSUSServer'
            value: wsusServer
          }
        ]
      : [
          {
            name: 'Service'
            value: updateService
          }
        ]
    source: {
      script: loadTextContent('../../../../.common/scripts/Invoke-WindowsUpdate.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    secondImageVmRestart
  ]
}

resource thirdImageVmRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installUpdates) {
  name: 'restart-vm-3'
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
    microsoftUpdates
  ]
}

resource vdot 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installVirtualDesktopOptimizationTool) {
  name: 'vdot'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri) ? null : '${logBlobContainerUri}${imageVmName}-vdot-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-vdot-output-${timeStamp}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Name'
        value: 'VDOT'
      }
      {
        name: 'Uri'
        value: !startsWith(cloud, 'us') && (downloadLatestMicrosoftContent || empty(artifactsContainerUri))
          ? downloads.VirtualDesktopOptimizationTool.DownloadUrl
          : '${artifactsContainerUri}/${downloads.VirtualDesktopOptimizationTool.DestinationFileName}'
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Invoke-VDOT.ps1')
    }
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    thirdImageVmRestart
  ]
}

resource fourthImageVmRestart 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installVirtualDesktopOptimizationTool) {
  name: 'restart-vm-4'
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
    vdot
  ]
}

@batchSize(1)
resource vdiApplications 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = [
  for customizer in vdiCustomizers: {
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
        : '${logBlobContainerUri}${imageVmName}-${customizer.name}-error-${timeStamp}.log'
      outputBlobManagedIdentity: empty(logBlobContainerUri)
        ? null
        : {
            clientId: userAssignedIdentityClientId
          }
      outputBlobUri: empty(logBlobContainerUri)
        ? null
        : '${logBlobContainerUri}${imageVmName}-${customizer.name}-output-${timeStamp}.log'
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
    dependsOn: [
      firstImageVmRestart
      secondImageVmRestart
      thirdImageVmRestart
      fourthImageVmRestart
    ]
  }
]

resource cleanup 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'cleanup-Image'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: true    
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-DiskCleanup-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-DiskCleanup-output-${timeStamp}.log'
    parameters: [
      {
        name: 'BuildDir'
        value: buildDir
      }
      {
        name: 'CleanupDesktop'
        value: string(cleanupDesktop)
      }
    ]
    source: {
      script: loadTextContent('../../../../.common/scripts/Invoke-DiskCleanup.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    firstImageVmRestart
    secondImageVmRestart
    thirdImageVmRestart
    fourthImageVmRestart
    vdiApplications
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
      : '${logBlobContainerUri}${imageVmName}-Sysprep-error-${timeStamp}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Sysprep-output-${timeStamp}.log'
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
    source: {
      script: loadTextContent('../../../../.common/scripts/Invoke-Sysprep.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    cleanup
  ]
}

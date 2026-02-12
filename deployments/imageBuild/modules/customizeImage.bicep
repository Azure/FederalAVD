targetScope = 'resourceGroup'

@secure()
param adminPw string
param applyWindowsDesktopOptimizations bool
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
param office365AppsToInstall array
param teamsCloudType string
param deploymentSuffix string = utcNow('yyMMddhhmm')
param updateService string
param userAssignedIdentityClientId string
param vdiCustomizations array
param wsusServer string

var apiVersion = startsWith(cloud, 'usn') ? '2017-08-01' : '2018-02-01'

#disable-next-line BCP329
var envSuffix = substring(environment().suffixes.storage, 5, length(environment().suffixes.storage) - 5)

var buildDir = 'c:\\BuildDir'

var customizers = [
  for customization in customizations: {
    name: replace(customization.name, ' ', '-')
    uri: contains(customization.blobNameOrUri, '://')
      ? customization.blobNameOrUri
      : '${artifactsContainerUri}/${customization.blobNameOrUri}'
    arguments: customization.?arguments ?? ''
    restart: customization.?restart ?? false
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

var useBuildDir = !empty(customizations) || installFsLogix || !empty(office365AppsToInstall) || installOneDrive || installTeams || applyWindowsDesktopOptimizations || !empty(vdiCustomizations)

var customizationBatchSize = 20
var customizersCount = length(customizers)
var batchCount = customizersCount / customizationBatchSize + (customizersCount % customizationBatchSize > 0 ? 1 : 0)

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

resource imageVm 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
  name: imageVmName
}

resource orchestrationVm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: orchestrationVmName
}

resource createBuildDir 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (useBuildDir) {
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
      : '${logBlobContainerUri}${imageVmName}-Remove-AppxPackages-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Remove-AppxPackages-output-${deploymentSuffix}.log'
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
      : '${logBlobContainerUri}${imageVmName}-FSLogix-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-FSLogix-output-${deploymentSuffix}.log'
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
    createBuildDir
    removeAppxPackages
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
      : '${logBlobContainerUri}${imageVmName}-Office-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Office-output-${deploymentSuffix}.log'
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
    createBuildDir
    removeAppxPackages
    fslogix
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
      : '${logBlobContainerUri}${imageVmName}-OneDrive-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-OneDrive-output-${deploymentSuffix}.log'
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
    createBuildDir
    removeAppxPackages
    fslogix
    office
  ]
}

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
      : '${logBlobContainerUri}${imageVmName}-Teams-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Teams-output-${deploymentSuffix}.log'
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
    createBuildDir
    removeAppxPackages
    fslogix
    office
    onedrive
  ]
}

resource removeRunCommandsMicrosoftSoftware 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = if (length(customizations) + length(vdiCustomizations) > 13) {
  parent: orchestrationVm
  name: 'remove-microsoft-software-runCommands'
  location: location
  properties: {
    asyncExecution: true
    parameters: [
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'SubscriptionId'
        value: subscription().subscriptionId
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
        value: resourceGroup().name
      }
    ]
    source: {
      script: loadTextContent('../../../../.common/scripts/Remove-RunCommands.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    createBuildDir
    removeAppxPackages
    fslogix
    onedrive
    office
    teams
  ]
}

resource restartMicrosoftSoftware 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (!empty(appsToRemove) || installFsLogix || !empty(office365AppsToInstall) || installOneDrive || installTeams) {
  name: 'restart-post-microsoft-software'
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
    fslogix
    office
    onedrive
    teams
    removeRunCommandsMicrosoftSoftware
  ]
}

@batchSize(1)
module customizationBatches 'applyCustomizationsBatch.bicep' = [for i in range(0, batchCount): {
  name: 'customization-batch-${i}-${deploymentSuffix}'
  params: {
    batchIndex: i
    commonScriptParams: commonScriptParams
    customizations: map(filter(range(0, customizationBatchSize), j => (i * customizationBatchSize + j) < customizersCount), j => {
      name: customizers[i * customizationBatchSize + j].name
      uri: customizers[i * customizationBatchSize + j].uri
      arguments: customizers[i * customizationBatchSize + j].arguments
      restart: customizers[i * customizationBatchSize + j].restart
    })
    deploymentSuffix: deploymentSuffix
    imageVmName: imageVmName
    location: location
    logBlobContainerUri: logBlobContainerUri
    orchestrationVmName: orchestrationVmName
    resourceGroupName: resourceGroup().name
    resourceManagerUri: environment().resourceManager
    subscriptionId: subscription().subscriptionId
    userAssignedIdentityClientId: userAssignedIdentityClientId
    restartVMParameters: restartVMParameters
  }
  dependsOn: [
    createBuildDir
    restartMicrosoftSoftware
  ]
}]

resource restartCustomizations 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (!empty(customizations)) {
  name: 'restart-post-customizations'
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
    customizationBatches
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
      : '${logBlobContainerUri}${imageVmName}-Install-Updates-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Install-Updates-output-${deploymentSuffix}.log'
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
    restartMicrosoftSoftware
    restartCustomizations
  ]
}

resource restartUpdates 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installUpdates) {
  name: 'restart-post-updates'
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

resource wdot 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (applyWindowsDesktopOptimizations) {
  name: 'wdot'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: false
    errorBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    errorBlobUri: empty(logBlobContainerUri) ? null : '${logBlobContainerUri}${imageVmName}-wdot-error-${deploymentSuffix}.log'
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-wdot-output-${deploymentSuffix}.log'
    parameters: union(commonScriptParams, [
      {
        name: 'Name'
        value: 'WDOT'
      }
      {
        name: 'Uri'
        value: !startsWith(cloud, 'us') && (downloadLatestMicrosoftContent || empty(artifactsContainerUri))
          ? downloads.WindowsDesktopOptimizationTool.DownloadUrl
          : '${artifactsContainerUri}/${downloads.WindowsDesktopOptimizationTool.DestinationFileName}'
      }
    ])
    source: {
      script: loadTextContent('../../../../.common/scripts/Invoke-WDOT.ps1')
    }
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    createBuildDir
    restartMicrosoftSoftware
    restartCustomizations
    restartUpdates
  ]
}

resource restartWDOT 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (applyWindowsDesktopOptimizations) {
  name: 'restart-post-wdot'
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
    wdot
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
    dependsOn: [
      createBuildDir
      restartMicrosoftSoftware
      restartCustomizations
      restartUpdates
      restartWDOT
    ]
  }
]

resource cleanupPublicDesktop 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (cleanupDesktop) {
  name: 'clean-PublicDesktop'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: true
    source: {
      script: '''
        Remove-Item "$Env:Public\Desktop\*" -Force -ErrorAction SilentlyContinue
      '''
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    createBuildDir
    restartMicrosoftSoftware
    restartCustomizations
    restartUpdates
    restartWDOT
    vdiApplications
  ]
}

resource removeBuildDir 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (useBuildDir) {
  name: 'remove-BuildDir'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: true
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
        Remove-Item -Path $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
      '''
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    createBuildDir
    restartMicrosoftSoftware
    restartCustomizations
    restartUpdates
    restartWDOT
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
      script: loadTextContent('../../../../.common/scripts/Invoke-Sysprep.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    restartMicrosoftSoftware
    restartCustomizations
    restartUpdates
    restartWDOT
    vdiApplications
    cleanupPublicDesktop
    removeBuildDir
  ]
}

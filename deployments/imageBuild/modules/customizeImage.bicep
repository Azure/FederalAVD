targetScope = 'resourceGroup'

@description('The optimization profile to apply. NonPersistent-UpdatesOnly locks down update channels only; NonPersistent-Full applies full VDI optimization; Persistent applies full optimization minus update-channel lockdown; None skips optimization (AirGapped still applies).')
@allowed(['None', 'NonPersistent-UpdatesOnly', 'NonPersistent-Full', 'Persistent'])
param vdiOptimizationProfile string

@description('When true, applies settings for air-gapped or internet-restricted environments: disables SmartScreen cloud lookups, online font providers, Teredo IPv6, WER uploads, and DiagTrack telemetry. Applies independently of vdiOptimizationProfile, including when profile is None.')
param vdiOptimizationAirGapped bool = false
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
param deploymentSuffix string
param updateService string
param userAssignedIdentityClientId string
param vdiCustomizations array
param wsusServer string

var apiVersion = startsWith(cloud, 'usn') ? '2017-08-01' : '2018-02-01'

#disable-next-line BCP329
var envSuffix = substring(environment().suffixes.storage, 5, length(environment().suffixes.storage) - 5)

var buildDir = 'c:\\BuildDir'
var restartVmScript = loadTextContent('../../../.common/scripts/Restart-Vm.ps1')
var customizationScript = loadTextContent('../../../.common/scripts/Invoke-Customization.ps1')

var customizers = [
  for customization in customizations: {
    name: replace(customization.name, ' ', '-')
    uri: startsWith(toLower(customization.blobNameOrUri), 'https://') || startsWith(toLower(customization.blobNameOrUri), 'http://')
      ? customization.blobNameOrUri
      : '${artifactsContainerUri}/${customization.blobNameOrUri}'
    arguments: customization.?arguments ?? ''
    restart: customization.?restart ?? false
  }
]

var vdiCustomizers = [
  for customization in vdiCustomizations: {
    name: replace(customization.name, ' ', '-')
    uri: startsWith(toLower(customization.blobNameOrUri), 'https://') || startsWith(toLower(customization.blobNameOrUri), 'http://')
      ? customization.blobNameOrUri
      : '${artifactsContainerUri}/${customization.blobNameOrUri}'
    arguments: customization.?arguments ?? ''
  }
]

var useBuildDir = !empty(customizations) || installFsLogix || !empty(office365AppsToInstall) || installOneDrive || installTeams || !empty(vdiCustomizations)

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

// CBS check before any customization work begins.
// Marketplace images are sometimes published with pending CBS state (a WU cycle ran
// during image preparation but the VM was not rebooted before capture). Running with
// a dirty component store can cause Windows Update failures, FSLogix/Office install
// issues, and unpredictable customization behaviour. This step costs ~60s in the
// clean case and a full reboot only when the marketplace image actually needs it.
module conditionalRestartPreBuild 'conditionalRestart.bicep' = {
  name: 'cbs-status-conditional-restart-pre-build-${deploymentSuffix}'
  params: {
    imageVmName: imageVmName
    location: location
    logBlobContainerUri: logBlobContainerUri
    orchestrationVmName: orchestrationVmName
    userAssignedIdentityClientId: userAssignedIdentityClientId
    deploymentSuffix: deploymentSuffix
    context: 'PreBuild'
  }
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
  dependsOn: [
    conditionalRestartPreBuild
  ]
}

resource removeAppxPackages 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = if (!empty(appsToRemove)) {
  name: 'remove-appxPackages'
  location: location
  parent: imageVm
  properties: {
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Remove-AppxPackages-${deploymentSuffix}.log'
    parameters: [
      {
        name: 'AppsToRemove'
        value: string(appsToRemove)
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Remove-AppXPackages.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    conditionalRestartPreBuild
  ]
}

resource fslogix 'Microsoft.Compute/virtualMachines/runCommands@2023-07-01' = if (installFsLogix) {
  name: 'fslogix'
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
      : '${logBlobContainerUri}${imageVmName}-FSLogix-${deploymentSuffix}.log'
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
      script: loadTextContent('../../../.common/scripts/Install-FSLogix.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    createBuildDir
    removeAppxPackages
    conditionalRestartPreBuild
  ]
}

resource office 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (!empty(office365AppsToInstall)) {
  name: 'm365Apps'
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
      : '${logBlobContainerUri}${imageVmName}-Office-${deploymentSuffix}.log'
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
      script: loadTextContent('../../../.common/scripts/Install-M365Applications.ps1')
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
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-OneDrive-${deploymentSuffix}.log'
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
      script: loadTextContent('../../../.common/scripts/Install-OneDrive.ps1')
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
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Teams-${deploymentSuffix}.log'
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
      script: loadTextContent('../../../.common/scripts/Install-Teams.ps1')
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
      script: loadTextContent('../../../.common/scripts/Remove-RunCommands.ps1')
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

resource restartMicrosoftSoftware 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (installFsLogix || !empty(office365AppsToInstall) || installOneDrive || installTeams) {
  name: 'restart-post-microsoft-software'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    parameters: restartVMParameters
    source: {
      script: restartVmScript
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
module customizationBatches 'applyCustomizationsBatch.bicep' = [
  for i in range(0, batchCount): {
    name: 'customization-batch-${i}-${deploymentSuffix}'
    params: {
      batchIndex: i
      commonScriptParams: commonScriptParams
      customizations: map(
        filter(range(0, customizationBatchSize), j => (i * customizationBatchSize + j) < customizersCount),
        j => {
          name: customizers[i * customizationBatchSize + j].name
          uri: customizers[i * customizationBatchSize + j].uri
          arguments: customizers[i * customizationBatchSize + j].arguments
          restart: customizers[i * customizationBatchSize + j].restart
        }
      )
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
  }
]

resource restartCustomizations 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (!empty(customizations)) {
  name: 'restart-post-customizations'
  location: location
  parent: orchestrationVm
  properties: {
    asyncExecution: false
    parameters: restartVMParameters
    source: {
      script: restartVmScript
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
    outputBlobManagedIdentity: empty(logBlobContainerUri)
      ? null
      : {
          clientId: userAssignedIdentityClientId
        }
    outputBlobUri: empty(logBlobContainerUri)
      ? null
      : '${logBlobContainerUri}${imageVmName}-Install-Updates-${deploymentSuffix}.log'
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
      script: loadTextContent('../../../.common/scripts/Invoke-WindowsUpdate.ps1')
    }
    timeoutInSeconds: 3600
    treatFailureAsDeploymentFailure: false
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
      script: restartVmScript
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    microsoftUpdates
  ]
}

module conditionalRestartPostUpdates 'conditionalRestart.bicep' = if (installUpdates) {
  name: 'conditional-restart-post-updates-${deploymentSuffix}'
  params: {
    imageVmName: imageVmName
    location: location
    logBlobContainerUri: logBlobContainerUri
    orchestrationVmName: orchestrationVmName
    userAssignedIdentityClientId: userAssignedIdentityClientId
    deploymentSuffix: deploymentSuffix
    context: 'PostUpdates'
  }
  dependsOn: [
    restartUpdates
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
      outputBlobManagedIdentity: empty(logBlobContainerUri)
        ? null
        : {
            clientId: userAssignedIdentityClientId
          }
      outputBlobUri: empty(logBlobContainerUri)
        ? null
        : '${logBlobContainerUri}${imageVmName}-${customizer.name}-${deploymentSuffix}.log'
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
        script: customizationScript
      }
      treatFailureAsDeploymentFailure: true
    }
    dependsOn: [
      createBuildDir
      restartMicrosoftSoftware
      restartCustomizations
      conditionalRestartPostUpdates
    ]
  }
]

resource cleanupPublicDesktop 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (cleanupDesktop) {
  name: 'clean-PublicDesktop'
  location: location
  parent: imageVm
  properties: {
    asyncExecution: false
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
    conditionalRestartPostUpdates
    vdiApplications
  ]
}

resource optimizeImage 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = if (vdiOptimizationProfile != 'None' || vdiOptimizationAirGapped) {
  name: 'optimize-image'
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
      : '${logBlobContainerUri}${imageVmName}-Optimize-AVDImage-${deploymentSuffix}.log'
    parameters: [
      {
        name: 'OptimizationProfile'
        value: vdiOptimizationProfile
      }
      {
        name: 'AirGapped'
        value: string(vdiOptimizationAirGapped)
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Optimize-AVDImage.ps1')
    }
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    createBuildDir
    restartMicrosoftSoftware
    restartCustomizations
    conditionalRestartPostUpdates
    vdiApplications
  ]
}

resource cleanupImage 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'cleanup-image'
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
      : '${logBlobContainerUri}${imageVmName}-Cleanup-Image-${deploymentSuffix}.log'
    parameters: [
      {
        name: 'BuildDir'
        value: buildDir
      }
    ]
    source: {
      script: loadTextContent('../../../.common/scripts/Invoke-DiskCleanup.ps1')
    }
    treatFailureAsDeploymentFailure: false
  }
  dependsOn: [
    createBuildDir
    restartMicrosoftSoftware
    restartCustomizations
    conditionalRestartPostUpdates
    vdiApplications
    optimizeImage
  ]
}

// CBS check and conditional restart before sysprep.
// Skipped when vdiCustomizers are present — restarts after vdiCustomizations
// are not permitted, and vdiCustomizations should not install OS components
// that dirty CBS. When vdiCustomizers are absent, cleanupImage is the last
// write step and CBS is checked to ensure sysprep runs on a settled system.

module conditionalRestartPostCleanup 'conditionalRestart.bicep' = if (empty(vdiCustomizers)) {
  name: 'conditional-restart-post-cleanup-${deploymentSuffix}'
  params: {
    imageVmName: imageVmName
    location: location
    logBlobContainerUri: logBlobContainerUri
    orchestrationVmName: orchestrationVmName
    userAssignedIdentityClientId: userAssignedIdentityClientId
    deploymentSuffix: deploymentSuffix
    context: 'PostCleanup'
  }
  dependsOn: [
    cleanupImage
  ]
}

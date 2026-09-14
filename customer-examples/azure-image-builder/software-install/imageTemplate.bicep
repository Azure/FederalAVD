// Sample Azure VM Image Builder (AIB) template: FSLogix, Microsoft 365 Apps, OneDrive, and Teams
// (built-in software, same scripts imageBuild.bicep uses) plus 7-Zip and Google Chrome Enterprise
// as generic customizers using the blob + managed-identity method (the same one imageBuild.bicep
// uses, via deployments/shared/scripts/Invoke-Customization.ps1).
//
// Read ../README.md first: AIB delivers files very differently than Packer. There is no local
// machine uploading files over a live connection -- AIB customizer scripts are embedded directly
// into this Bicep template at compile time (loadTextContent, exactly like imageBuild.bicep's own
// runCommand modules), and any actual installer payloads are downloaded by those scripts from blob
// storage using the build VM's managed identity. See ../README.md "How Files Reach the Build VM".

@description('Azure region for the image template and build VM. Must support Azure VM Image Builder.')
param location string

@description('Name of the Microsoft.VirtualMachineImages/imageTemplates resource.')
param imageTemplateName string

@description('Resource ID of the user-assigned identity AIB uses to manage the image template itself (read/write the gallery image, read scripts). Needs Contributor on this resource group and the gallery.')
param imageTemplateIdentityResourceId string

@description('Resource ID of the user-assigned identity attached to the build VM. Customizer scripts use this identity client ID to authenticate to blob storage. Needs Storage Blob Data Reader on the artifacts container.')
param buildVmIdentityResourceId string

@description('Resource ID of an existing subnet for the build VM. No public IP is created when this is set (mirrors the subnetResourceId parameter in imageBuild.bicep).')
param subnetResourceId string

@description('Optional. Resource ID of an existing subnet delegated to Azure Container Instance, for an isolated build. Leave blank to use the default AIB proxy VM.')
param containerInstanceSubnetResourceId string = ''

param vmSize string = 'Standard_D4ads_v6'
param osDiskSizeGB int = 0

@description('Marketplace source image.')
param imagePublisher string
param imageOffer string
param imageSku string

@description('Resource ID of the destination Compute Gallery image definition, e.g. .../galleries/<gallery>/images/<definition>.')
param galleryImageDefinitionResourceId string

@description('Image version to publish. Leave blank to let AIB auto-generate one.')
param imageVersion string = ''

param targetRegions array = [
  {
    name: location
    replicaCount: 1
    storageAccountType: 'Standard_LRS'
  }
]

param excludeFromLatest bool = false

@description('Base blob container URL for customizer artifacts, e.g. https://<account>.blob.core.windows.net/artifacts.')
param artifactsContainerUri string = ''

param blobStorageSuffix string = environment().suffixes.storage
param apiVersion string = '2018-02-01'

param installFslogix bool = false
param fslogixUri string = 'https://aka.ms/fslogix_download'

param office365AppsToInstall array = []
param cloudEnvironmentName string = 'Public'

param installOneDrive bool = false
param onedriveUri string = 'https://go.microsoft.com/fwlink/?linkid=844652'

param installTeams bool = false
param teamsCloudType string = 'Commercial'
param teamsUris array = []
param teamsDestFileNames array = []

param installChrome bool = false
param chromeBlobName string = 'Google-Chrome-Enterprise/GoogleChromeEnterprise.zip'
param chromeArguments string = '-DeploymentType Install'

param install7zip bool = false
param sevenZipBlobName string = '7-Zip/Deploy-7-Zip.zip'

param installUpdates bool = false

param buildTimeoutInMinutes int = 180

@description('Optional. Resource ID of an existing, empty resource group for AIB to use as its staging resource group instead of creating an ephemeral "IT_*" one. Must be empty, in the same region as this template, and already granted Contributor (or Owner) on imageTemplateIdentityResourceId before this deploys. See ../README.md "Staging Resource Group".')
param stagingResourceGroupResourceId string = ''

@description('Optional. Tags applied to the resources AIB creates inside the staging resource group (its own storage account, VNet/NSG, container instance, etc.), useful for satisfying tag-based Azure Policy requirements without a custom stagingResourceGroupResourceId.')
param managedResourceTags object = {}

param tags object = {}

// Resolve the build VM identity's client ID directly from the resource -- unlike Packer HCL, Bicep
// can read this straight off the identity resource; no manual `az identity show` lookup needed.
resource buildVmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(buildVmIdentityResourceId, '/'))
  scope: resourceGroup(split(buildVmIdentityResourceId, '/')[2], split(buildVmIdentityResourceId, '/')[4])
}
var buildVmIdentityClientId = buildVmIdentity.properties.clientId

// Builds a PowerShell customizer's inline command array: writes scriptContent to destinationPath
// via a single-quoted here-string (no $variable expansion of the pasted script's own content),
// then runs invocation. This mirrors imageBuild.bicep's own loadTextContent() pattern -- these
// scripts are embedded directly in the template, not downloaded from anywhere at build time.
func buildEmbeddedScriptInline(scriptContent string, destinationPath string, invocation string) string[] => concat(
  [
    'New-Item -Path (Split-Path -Path \'${destinationPath}\' -Parent) -ItemType Directory -Force | Out-Null'
    '$ScriptContent = @\''
  ],
  split(scriptContent, ['\r\n', '\n']),
  [
    '\'@'
    'Set-Content -LiteralPath \'${destinationPath}\' -Value $ScriptContent -Encoding UTF8'
    invocation
  ]
)

var installMicrosoftSoftware = installFslogix || !empty(office365AppsToInstall) || installOneDrive || installTeams
var installCustomizers = installChrome || install7zip

var fslogixCustomizers = installFslogix ? [
  {
    type: 'PowerShell'
    name: 'InstallFSLogix'
    runElevated: true
    runAsSystem: true
    inline: buildEmbeddedScriptInline(
      loadTextContent('../../../deployments/imageBuild/scripts/Install-FSLogix.ps1'),
      'C:\\Windows\\Temp\\aibScripts\\Install-FSLogix.ps1',
      '& \'C:\\Windows\\Temp\\aibScripts\\Install-FSLogix.ps1\' -APIVersion \'${apiVersion}\' -BlobStorageSuffix \'${blobStorageSuffix}\' -UserAssignedIdentityClientId \'${buildVmIdentityClientId}\' -Uri \'${fslogixUri}\''
    )
  }
] : []

var m365Customizers = !empty(office365AppsToInstall) ? [
  {
    type: 'PowerShell'
    name: 'InstallM365Apps'
    runElevated: true
    runAsSystem: true
    inline: buildEmbeddedScriptInline(
      loadTextContent('../../../deployments/imageBuild/scripts/Install-M365Applications.ps1'),
      'C:\\Windows\\Temp\\aibScripts\\Install-M365Applications.ps1',
      '& \'C:\\Windows\\Temp\\aibScripts\\Install-M365Applications.ps1\' -APIVersion \'${apiVersion}\' -AppsToInstall \'${string(office365AppsToInstall)}\' -BlobStorageSuffix \'${blobStorageSuffix}\' -Environment \'${cloudEnvironmentName}\' -UserAssignedIdentityClientId \'${buildVmIdentityClientId}\''
    )
  }
] : []

var onedriveCustomizers = installOneDrive ? [
  {
    type: 'PowerShell'
    name: 'InstallOneDrive'
    runElevated: true
    runAsSystem: true
    inline: buildEmbeddedScriptInline(
      loadTextContent('../../../deployments/imageBuild/scripts/Install-OneDrive.ps1'),
      'C:\\Windows\\Temp\\aibScripts\\Install-OneDrive.ps1',
      '& \'C:\\Windows\\Temp\\aibScripts\\Install-OneDrive.ps1\' -APIVersion \'${apiVersion}\' -BlobStorageSuffix \'${blobStorageSuffix}\' -UserAssignedIdentityClientId \'${buildVmIdentityClientId}\' -Uri \'${onedriveUri}\''
    )
  }
] : []

var teamsCustomizers = installTeams ? [
  {
    type: 'PowerShell'
    name: 'InstallTeams'
    runElevated: true
    runAsSystem: true
    inline: buildEmbeddedScriptInline(
      loadTextContent('../../../deployments/imageBuild/scripts/Install-Teams.ps1'),
      'C:\\Windows\\Temp\\aibScripts\\Install-Teams.ps1',
      '& \'C:\\Windows\\Temp\\aibScripts\\Install-Teams.ps1\' -APIVersion \'${apiVersion}\' -BlobStorageSuffix \'${blobStorageSuffix}\' -UserAssignedIdentityClientId \'${buildVmIdentityClientId}\' -TeamsCloudType \'${teamsCloudType}\' -Uris \'${string(teamsUris)}\' -DestFileNames \'${string(teamsDestFileNames)}\''
    )
  }
] : []

var restartAfterSoftwareCustomizers = installMicrosoftSoftware ? [
  {
    type: 'WindowsRestart'
    restartTimeout: '15m'
  }
] : []

// Generic customizers: same Invoke-Customization.ps1 imageBuild.bicep uses, embedded once, then
// invoked once per customizer -- no per-item file delivery needed since the script downloads its
// own payload from artifactsContainerUri using the build VM's managed identity.
var invokeCustomizationScriptContent = installCustomizers ? loadTextContent('../../../deployments/shared/scripts/Invoke-Customization.ps1') : ''
var invokeCustomizationRemotePath = 'C:\\Windows\\Temp\\aibScripts\\Invoke-Customization.ps1'

var chromeCustomizers = installChrome ? [
  {
    type: 'PowerShell'
    name: 'DeployInvokeCustomizationScript'
    runElevated: true
    runAsSystem: true
    inline: buildEmbeddedScriptInline(invokeCustomizationScriptContent, invokeCustomizationRemotePath, 'Write-Output \'Invoke-Customization.ps1 staged.\'')
  }
  {
    type: 'PowerShell'
    name: 'CustomizeChrome'
    runElevated: true
    runAsSystem: true
    inline: [
      '& \'${invokeCustomizationRemotePath}\' -APIVersion \'${apiVersion}\' -BlobStorageSuffix \'${blobStorageSuffix}\' -Name \'Google-Chrome-Enterprise\' -Uri \'${artifactsContainerUri}/${chromeBlobName}\' -UserAssignedIdentityClientId \'${buildVmIdentityClientId}\' -Arguments \'${chromeArguments}\''
    ]
  }
] : []

var sevenZipCustomizers = install7zip ? concat(
  // Only stage Invoke-Customization.ps1 here if Chrome didn't already do it above.
  installChrome ? [] : [
    {
      type: 'PowerShell'
      name: 'DeployInvokeCustomizationScriptFor7Zip'
      runElevated: true
      runAsSystem: true
      inline: buildEmbeddedScriptInline(invokeCustomizationScriptContent, invokeCustomizationRemotePath, 'Write-Output \'Invoke-Customization.ps1 staged.\'')
    }
  ],
  [
    {
      type: 'PowerShell'
      name: 'Customize7Zip'
      runElevated: true
      runAsSystem: true
      inline: [
        '& \'${invokeCustomizationRemotePath}\' -APIVersion \'${apiVersion}\' -BlobStorageSuffix \'${blobStorageSuffix}\' -Name \'7-Zip\' -Uri \'${artifactsContainerUri}/${sevenZipBlobName}\' -UserAssignedIdentityClientId \'${buildVmIdentityClientId}\''
      ]
    }
  ]
) : []

var windowsUpdateCustomizers = installUpdates ? [
  {
    type: 'WindowsUpdate'
    searchCriteria: 'IsInstalled=0'
    filters: [
      'exclude:$_.Title -like \'*Preview*\''
      'include:$true'
    ]
    updateLimit: 40
  }
  {
    type: 'WindowsRestart'
    restartTimeout: '30m'
  }
] : []

var diskCleanupCustomizers = [
  {
    type: 'PowerShell'
    name: 'DiskCleanup'
    runElevated: true
    runAsSystem: true
    inline: buildEmbeddedScriptInline(
      loadTextContent('../../../deployments/imageBuild/scripts/Invoke-DiskCleanup.ps1'),
      'C:\\Windows\\Temp\\aibScripts\\Invoke-DiskCleanup.ps1',
      '& \'C:\\Windows\\Temp\\aibScripts\\Invoke-DiskCleanup.ps1\''
    )
  }
]

// No Sysprep customizer here: AIB always runs its own generalize/Sysprep step automatically after
// the last customizer (see ../README.md "Generalize/Sysprep Is Automatic").
resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: imageTemplateName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${imageTemplateIdentityResourceId}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes
    stagingResourceGroup: empty(stagingResourceGroupResourceId) ? null : stagingResourceGroupResourceId
    managedResourceTags: managedResourceTags
    source: {
      type: 'PlatformImage'
      publisher: imagePublisher
      offer: imageOffer
      sku: imageSku
      version: 'latest'
    }
    vmProfile: {
      vmSize: vmSize
      osDiskSizeGB: osDiskSizeGB
      userAssignedIdentities: [
        buildVmIdentityResourceId
      ]
      vnetConfig: {
        subnetId: subnetResourceId
        containerInstanceSubnetId: empty(containerInstanceSubnetResourceId) ? null : containerInstanceSubnetResourceId
      }
    }
    customize: concat(
      fslogixCustomizers,
      m365Customizers,
      onedriveCustomizers,
      teamsCustomizers,
      restartAfterSoftwareCustomizers,
      chromeCustomizers,
      sevenZipCustomizers,
      windowsUpdateCustomizers,
      diskCleanupCustomizers
    )
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: empty(imageVersion) ? galleryImageDefinitionResourceId : '${galleryImageDefinitionResourceId}/versions/${imageVersion}'
        runOutputName: '${imageTemplateName}-output'
        excludeFromLatest: excludeFromLatest
        targetRegions: targetRegions
      }
    ]
    autoRun: {
      state: 'Enabled'
    }
  }
}

output imageTemplateResourceId string = imageTemplate.id

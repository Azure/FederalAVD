targetScope = 'subscription'

// Builds a custom Windows image for Azure Virtual Desktop using a zero-trust architecture.
// Creates a temporary build VM, applies software customizations, captures the result to an Azure Compute Gallery,
// and cleans up all temporary resources. Does not require the Azure VM Image Builder service.

@description('Value appended to the deployment names.')
param timeStamp string = utcNow('yyyyMMddHHmmss')

@description('Deployment location. Note that the compute resources will be deployed to the region where the subnet is located.')
param location string = deployment().location

@description('Value to prepend to the deployment names.')
@maxLength(6)
param deploymentPrefix string = ''

@description('Optional. Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name.')
param nameConvResTypeAtEnd bool = false

// Required Existing Resources
@description('Azure Compute Gallery Resource Id.')
param computeGalleryResourceId string

@description('Optional. The full Uri of the artifacts storage container which contains (scripts, installers, etc) used during the image build.')
param artifactsContainerUri string = ''

@description('Optional. The resource Id of the user assigned managed identity used to access the artifacts storage account.')
param userAssignedIdentityResourceId string = ''

@description('The resource Id of the subnet to which the image build VM will be attached.')
param subnetResourceId string

@description('The resource Id of an existing resource group in which to create the vms to build the image. Leave blank to create a new resource group.')
param imageBuildResourceGroupId string = ''

// Optional Custom Naming
@description('The custom name of the resource group where the image build vm and orchestration vm will be created. Leave blank to create a new resource group based on Cloud Adoption Framework naming principals.')
param customBuildResourceGroupName string = ''

// Source Image Properties
@description('Optional. The resource Id of the source image to use for the image build. If not provided, the latest image from the specified publisher, offer, and sku will be used.')
param customSourceImageResourceId string = ''

@description('The Marketplace Image publisher')
param mpPublisher string

@description('The Marketplace Image offer')
param mpOffer string

@description('The Marketplace Image sku')
param mpSku string

@description('Optional. Determines if "EncryptionAtHost" is enabled on the VMs.')
param encryptionAtHost bool = true

@description('The size of the Image build and Orchestration VMs.')
param vmSize string = 'Standard_D4ads_v6'

@allowed([
  0
  128
  256
  512
  1024
  2048
])
@description('Optional. The size of the OS disk in GB for the image build VM. When set to 0 it defaults to the image size - typically 128 GB.')
param diskSizeGB int = 0

// Image customizers
@description('Optional. List of Appx Apps to Remove. Default is [].')
param appsToRemove array = []

@description('Optional. Always download the newest bits from the web for FSLogix, Microsoft 365, OneDrive, and Teams. Overrides the default behavior of using the storage account.')
param downloadLatestMicrosoftContent bool = false

@description('Optional. Install FSLogix Agent.')
param installFsLogix bool = false

@description('Optional. List of Office 365 ProPlus Apps to Install. Default is [].')
param office365AppsToInstall array = []

@description('Optional. Install OneDrive Per Machine.')
param installOneDrive bool = false

@description('Optional. Install Microsoft Teams.')
param installTeams bool = false

@allowed([
  'Commercial'
  'GCC'
  'GCCH'
  'DoD'
  'GovSecret'
  'GovTopSecret'
  'Gallatin'
])
@description('Optional. The Teams Governmant Cloud type.')
param teamsCloudType string = 'Commercial'

@description('Optional. Apply the Windows Desktop Optimization Tool customizations.')
param applyWindowsDesktopOptimizations bool = false

@description('''Optional. Disable automatic software updates baked into the image.
Provide an array containing one or more of the following values to disable those update channels.
Omit a value to leave that channel enabled.
Valid values:
  disableWindowsUpdate
  disableM365Update
  disableTeamsUpdate
  disableOneDriveUpdate
  disableEdgeUpdate
  disableWebView2Update
  disableStoreAutoUpdate
Example: ["disableWindowsUpdate", "disableEdgeUpdate"]
''')
param disableSoftwareUpdates array = []

@description('''An array of image customization objects that are executed first before any restarts or updates.
Each object contains the following properties:
-name: Required. The name of the script or application that is running minus extension
-blobNameOrUri: Required. The blob name when used with the artifactsContainerUri or the full URI of the file to download.
-arguments: Optional. Arguments required by the installer or script being ran.

JSON example:
[
  {
    "name": "FSLogix",
    "blobNameOrUri": "https://aka.ms/fslogix_download"
  },
  {
    "name": "VSCode",
    "blobNameOrUri": "VSCode.zip",
    "arguments": "/verysilent /mergetasks=!runcode"
  }
]
''')
param customizations array = []

@description('''An array of image customization objects that are executed just before sysprep. These customizations are applications that
generate unique identifiers that should be removed before the image is generalized. Therefore, these customizations are executed without
restart switches to prevent the generation of these unique identifiers.
Each object contains the following properties:
-name: Required. The name of the script or application that is running minus extension
-blobNameOrUri: Required. The blob name when used with the artifactsContainerUri or the full URI of the file to download.
-arguments: Optional. Arguments required by the installer or script being ran.


JSON example:
[
  {
    "name": "ThirdPartyApp",
    "blobNameOrUri": "ThirdPartyApp.zip",
    "arguments": "MODE=VDI /norestart"
  }
]
''')
param vdiCustomizations array = []

@description('Optional. Remove all links from the public desktop.')
param cleanupDesktop bool = false

@description('Optional. Collect image customization logs.')
param collectCustomizationLogs bool = false

@description('Optional. Resource ID of an existing storage account (deployed by imageManagement with deployBuildLogsStorageAccount = true) to use for build customization logs. Required when collectCustomizationLogs is true.')
param logStorageAccountResourceId string = ''

@description('Optional. Name of the blob container in the logs storage account to write customization logs to.')
param logContainerName string = 'image-customization-logs'

@description('Optional. Resource ID of an existing Disk Encryption Set to use for gallery image version encryption. Created by the imageManagement template; pass its diskEncryptionSetResourceId output here to share the same DES across all image builds.')
param diskEncryptionSetResourceId string = ''

@description('Optional. Confidential VM encryption type applied to each image version replication target region. Only relevant when the image definition SecurityType is ConfidentialVM or ConfidentialVMSupported.')
@allowed([
  ''
  'EncryptedWithPmk'
  'EncryptedWithCmk'
  'EncryptedVMGuestStateOnlyWithPmk'
])
param galleryImageVersionConfidentialVMEncryptionType string = ''

@description('Optional. Resource ID of an existing Disk Encryption Set to use for Confidential VM guest state encryption in gallery image version replicas. When provided, no new DES is created. Only used when galleryImageVersionConfidentialVMEncryptionType is EncryptedWithCmk.')
param confidentialVMDiskEncryptionSetResourceId string = ''

@description('Optional. Determines if the latest updates from the specified update service will be installed.')
param installUpdates bool = true

@description('Optional. Determines if the built-in UWP (Store) apps will be updated during the image build.')
param updateUwpApps bool = false

@allowed([
  'MU'
  'WSUS'
])
@description('Optional. The update service.')
param updateService string = 'MU'

@description('Conditional. The WSUS Server Url if WSUS is specified. (i.e., https://wsus.corp.contoso.com:8531)')
param wsusServer string = ''

@description('Optional. The resource id of an existing Image Definition in the Compute gallery.')
param imageDefinitionResourceId string = ''

@description('''Conditional. The name of the image Definition to create in the Compute Gallery.
Only valid if [imageDefinitionResourceId] is not provided.
If left blank, the image definition name will be built on Cloud Adoption Framework principals and based on the [imageDefinitonPublisher], [imageDefinitionOffer], and [imageDefinitionSku] values.''')
@maxLength(80)
param customImageDefinitionName string = ''

@description('Conditional. The compute gallery image definition Publisher.')
@maxLength(128)
param imageDefinitionPublisher string = ''

@description('Conditional. The computer gallery image definition Offer.')
@maxLength(64)
param imageDefinitionOffer string = ''

@description('Conditional. The compute gallery image definition Sku.')
@maxLength(64)
param imageDefinitionSku string = ''

@description('Optional. Specifies whether the image definition supports the deployment of virtual machines with accelerated networking enabled.')
param imageDefinitionIsAcceleratedNetworkSupported bool = true

@description('Optional. Specifies whether the image definition supports creating VMs with support for hibernation.')
param imageDefinitionIsHibernateSupported bool = false

@description('Optional. Specifies whether the image definition supports capturing images of NVMe disks or Virtual Machines.')
param imageDefinitionIsHigherStoragePerformanceSupported bool = true

@allowed([
  'Standard'
  'ConfidentialVM'
  'ConfidentialVMSupported'
  'TrustedLaunch'
  'TrustedLaunchSupported'
  'TrustedLaunchAndConfidentialVMSupported'
])
param imageDefinitionSecurityType string = 'TrustedLaunch'

@description('''Optional. The image major version from 0 - 9999.
In order to specify a custom image version you must specify the [imageMajorVersion], [imageMinorVersion], and [imagePatch] integer from 0-9999.''')
@minValue(-1)
@maxValue(9999)
param imageMajorVersion int = -1

@description('''Optional. The image minor version from 0 - 9999.
In order to specify a custom image version you must specify the [imageMajorVersion], [imageMinorVersion], and [imagePatch] integer from 0-9999.''')
@minValue(-1)
@maxValue(9999)
param imageMinorVersion int = -1

@description('''Optional. The image patch version from 0 - 9999.
In order to specify a custom image version you must specify the [imageMajorVersion], [imageMinorVersion], and [imagePatch] integer from 0-9999.''')
@minValue(-1)
@maxValue(9999)
param imagePatch int = -1

@description('Optional. The number of days from now that the image version will reach end of life.')
param imageVersionEOLinDays int = 0

@description('Optional. The default image version replica count per region. This can be overwritten by the regional value.')
@minValue(1)
@maxValue(100)
param imageVersionDefaultReplicaCount int = 1

@description('Optional. Specifies the storage account type to be used to store the image. This property is not updatable.')
@allowed([
  'Premium_LRS'
  'Standard_LRS'
  'Standard_ZRS'
])
param imageVersionDefaultStorageAccountType string = 'Standard_LRS'

@description('Optional. Exclude this image version from the latest. This property can be overwritten by the regional value.')
param imageVersionExcludeFromLatest bool = false

@description('Optional. The regions to which the image version will be replicated. (Default: deployment location with Standard_LRS storage and 1 replica.)')
param imageVersionTargetRegions array = []

@description('Optional. The resource Id of the remote compute gallery.')
param remoteComputeGalleryResourceId string = ''

@description('Optional. Exclude this image version from the latest in the remote region.')
param remoteImageVersionExcludeFromLatest bool = false

@description('Optional. The default image version replica count in the remote region.')
param remoteImageVersionDefaultReplicaCount int = 1

@description('Optional. Specifies the storage account type to be used to store the image in the remote region. This property is not updatable.')
@allowed([
  'Premium_LRS'
  'Standard_LRS'
  'Standard_ZRS'
])
param remoteImageVersionStorageAccountType string = 'Standard_LRS'

@description('Optional. The tags to apply to all resources deployed by this template.')
param tags object = {}

// * VARIABLE DECLARATIONS * //

var deploymentSuffix = startsWith(deployment().name, 'Microsoft.Template-')
  ? substring(deployment().name, 19, 14)
  : timeStamp

// Function to ensure unique names in customization arrays by appending index to duplicates
var uniqueCustomizers = map(range(0, length(customizations)), i => {
  name: length(filter(customizations, item => item.name == customizations[i].name)) > 1
    ? '${customizations[i].name}-${length(filter(take(customizations, i + 1), item => item.name == customizations[i].name))}'
    : customizations[i].name
  blobNameOrUri: customizations[i].blobNameOrUri
  arguments: customizations[i].?arguments ?? ''
  restart: customizations[i].?restart ?? false
})

var uniqueVdiCustomizers = map(range(0, length(vdiCustomizations)), i => {
  name: length(filter(vdiCustomizations, item => item.name == vdiCustomizations[i].name)) > 1
    ? '${vdiCustomizations[i].name}-${length(filter(take(vdiCustomizations, i + 1), item => item.name == vdiCustomizations[i].name))}'
    : vdiCustomizations[i].name
  blobNameOrUri: vdiCustomizations[i].blobNameOrUri
  arguments: vdiCustomizations[i].?arguments ?? ''
})

var cloud = toLower(environment().name)
// account for air-gapped cloud location prefixes
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var locationsData = loadJsonContent('../../.common/data/locations.json')
var locations = startsWith(cloud, 'us') ? locationsData.other : locationsData[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')
var downloads = startsWith(cloud, 'usn')
  ? loadJsonContent('../../.common/data/topsecret.downloads.parameters.json')
  : startsWith(cloud, 'uss')
      ? loadJsonContent('../../.common/data/secret.downloads.parameters.json')
      : loadJsonContent('../../.common/data/public.downloads.parameters.json')

var computeLocation = vnet.location
var depPrefix = !empty(deploymentPrefix) ? '${deploymentPrefix}-' : ''
var imageBuildResourceGroupName = empty(imageBuildResourceGroupId)
  ? (empty(customBuildResourceGroupName)
      ? nameConvResTypeAtEnd
          ? 'avd-image-builds-${locations[varLocation].abbreviation}-${resourceAbbreviations.resourceGroups}'
          : '${resourceAbbreviations.resourceGroups}-avd-image-builds-${locations[varLocation].abbreviation}'
      : customBuildResourceGroupName)
  : last(split(imageBuildResourceGroupId, '/'))

var adminPw = '1qaz@WSX${uniqueString(subscription().id, imageBuildResourceGroupName)}'
var adminUserName = 'vmadmin'

var existingLogStorageAccountName = empty(logStorageAccountResourceId)
  ? ''
  : last(split(logStorageAccountResourceId, '/'))
var logContainerUri = collectCustomizationLogs && !empty(logStorageAccountResourceId)
  ? 'https://${existingLogStorageAccountName}.blob.${environment().suffixes.storage}/${logContainerName}/'
  : ''

var imageDefinitionFeatures = empty(imageDefinitionResourceId)
  ? filter(
      [
        imageDefinitionIsHibernateSupported ? { name: 'IsHibernateSupported', value: 'True' } : null
        imageDefinitionIsAcceleratedNetworkSupported ? { name: 'IsAcceleratedNetworkSupported', value: 'True' } : null
        imageDefinitionIsHigherStoragePerformanceSupported ? { name: 'DiskControllerTypes', value: 'SCSI, NVMe' } : null
        imageDefinitionSecurityType != 'Standard' ? { name: 'SecurityType', value: imageDefinitionSecurityType } : null
      ],
      item => item != null
    )
  : existingImageDefinition!.properties.features

var galleryImageDefinitionHyperVGeneration = endsWith(mpSku, 'g2') || startsWith(mpSku, 'win11') ? 'V2' : 'V1'
var galleryImageDefinitionName = empty(imageDefinitionResourceId)
  ? empty(customImageDefinitionName)
      ? nameConvResTypeAtEnd
          ? replace(
              '${replace(effectiveGalleryImageDefinitionPublisher, '-', '')}-${replace(effectiveGalleryImageDefinitionOffer, '-', '')}-${replace(effectiveGalleryImageDefinitionSku, '-', '')}-${resourceAbbreviations.imageDefinitions}',
              ' ',
              ''
            )
          : replace(
              '${resourceAbbreviations.imageDefinitions}-${replace(effectiveGalleryImageDefinitionPublisher, '-', '')}-${replace(effectiveGalleryImageDefinitionOffer, '-', '')}-${replace(effectiveGalleryImageDefinitionSku, '-', '')}',
              ' ',
              ''
            )
      : customImageDefinitionName
  : last(split(imageDefinitionResourceId, '/'))
var effectiveGalleryImageDefinitionOffer = !empty(imageDefinitionOffer)
  ? replace(imageDefinitionOffer, ' ', '')
  : mpOffer
var effectiveGalleryImageDefinitionPublisher = !empty(imageDefinitionPublisher)
  ? replace(imageDefinitionPublisher, ' ', '')
  : mpPublisher

var effectiveGalleryImageDefinitionSecurityType = empty(imageDefinitionResourceId)
  ? imageDefinitionSecurityType
  : !empty(filter(existingImageDefinition!.properties.features, feature => feature.name == 'SecurityType'))
      ? filter(existingImageDefinition!.properties.features, feature => feature.name == 'SecurityType')[0].value
      : 'Standard'
var effectiveGalleryImageDefinitionSku = !empty(imageDefinitionSku) ? replace(imageDefinitionSku, ' ', '') : mpSku
// build an image version from the ISO 8601 timestamp
var autoImageVersionName = '${substring(deploymentSuffix, 0, 4)}.${substring(deploymentSuffix, 4, 4)}.${substring(deploymentSuffix, 8, 4)}'
var imageVersionName = imageMajorVersion != -1 && imageMajorVersion != -1 && imagePatch != -1
  ? '${imageMajorVersion}.${imageMinorVersion}.${imagePatch}'
  : autoImageVersionName

var defaultLocalImageVersionTargetRegions = [
  {
    excludeFromLatest: imageVersionExcludeFromLatest
    name: computeLocation
    regionalReplicaCount: imageVersionDefaultReplicaCount
    storageAccountType: imageVersionDefaultStorageAccountType
  }
]

var defaultRemoteImageVersionTargetRegions = [
  {
    excludeFromLatest: remoteImageVersionExcludeFromLatest
    name: remoteLocation
    regionalReplicaCount: remoteImageVersionDefaultReplicaCount
    storageAccountType: 'Standard_LRS'
  }
]

var localImageVersionTargetRegions = !empty(imageVersionTargetRegions)
  ? empty(filter(imageVersionTargetRegions, region => region.name == computeLocation))
      ? union(defaultLocalImageVersionTargetRegions, imageVersionTargetRegions)
      : imageVersionTargetRegions
  : defaultLocalImageVersionTargetRegions

var imageVersionReplicationRegions = empty(remoteComputeGalleryResourceId)
  ? localImageVersionTargetRegions
  : empty(filter(localImageVersionTargetRegions, region => region.name == remoteLocation))
      ? union(localImageVersionTargetRegions, defaultRemoteImageVersionTargetRegions)
      : localImageVersionTargetRegions

// Note: auto-creation of a ConfidentialVM DES (ConfidentialVmEncryptedWithCustomerKey type) is a feature gap.
// CVM DES provisioning requires a Confidential VM Orchestrator service principal key-release role assignment
// that cannot be reliably automated here. Supply an existing DES via confidentialVMDiskEncryptionSetResourceId.
var effectiveConfidentialVmDiskEncryptionSetResourceId = galleryImageVersionConfidentialVMEncryptionType == 'EncryptedWithCmk'
  ? confidentialVMDiskEncryptionSetResourceId
  : ''

var imageVersionReplicationRegionsWithEncryption = empty(diskEncryptionSetResourceId)
  ? imageVersionReplicationRegions
  : map(
      imageVersionReplicationRegions,
      region =>
        union(region, {
          encryption: {
            osDiskImage: union(
              { diskEncryptionSetId: diskEncryptionSetResourceId },
              !empty(galleryImageVersionConfidentialVMEncryptionType)
                ? {
                    securityProfile: union(
                      { confidentialVMEncryptionType: galleryImageVersionConfidentialVMEncryptionType },
                      !empty(effectiveConfidentialVmDiskEncryptionSetResourceId)
                        ? { secureVMDiskEncryptionSetId: effectiveConfidentialVmDiskEncryptionSetResourceId }
                        : {}
                    )
                  }
                : {}
            )
          }
        })
    )

var imageVersionEndOfLifeDate = imageVersionEOLinDays > 0
  ? dateTimeAdd(deploymentSuffix, 'P${imageVersionEOLinDays}D')
  : ''

var imageVmName = take('${depPrefix}vmimg-${uniqueString(deploymentSuffix)}', 15)
var orchestrationVmName = take('${depPrefix}vmorc-${uniqueString(deploymentSuffix)}', 15)

var vmSecurityType = effectiveGalleryImageDefinitionSecurityType == 'TrustedLaunch'
  ? 'TrustedLaunch'
  : effectiveGalleryImageDefinitionSecurityType == 'ConfidentialVM' ? 'ConfidentialVM' : 'Standard'

var remoteLocation = !empty(remoteComputeGalleryResourceId) ? remoteComputeGallery!.location : ''

var vmAcceleratedNetworking = !empty(filter(
    imageDefinitionFeatures,
    feature => feature.name == 'IsAcceleratedNetworkSupported'
  ))
  ? bool(filter(imageDefinitionFeatures, feature => feature.name == 'IsAcceleratedNetworkSupported')[0]!.value)
  : false
var vmDiskControllerType = !empty(filter(imageDefinitionFeatures, feature => feature.name == 'DiskControllerTypes'))
  ? contains(filter(imageDefinitionFeatures, feature => feature.name == 'DiskControllerTypes')[0]!.value, 'NVMe')
      ? 'NVMe'
      : 'SCSI'
  : 'SCSI'

// * Prerequisite Resources * //

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: split(subnetResourceId, '/')[8]
  scope: resourceGroup(split(subnetResourceId, '/')[2], split(subnetResourceId, '/')[4])
}

// * Resource Group * //

resource imageBuildRg 'Microsoft.Resources/resourceGroups@2023-07-01' = if (empty(imageBuildResourceGroupId)) {
  name: imageBuildResourceGroupName
  location: location
  tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
}

// * Managed Identity * //

module userAssignedIdentity '../../.common/bicepModules/managedIdentity/userAssignedIdentities/deploy.bicep' = if (empty(userAssignedIdentityResourceId)) {
  name: '${depPrefix}ManagedIdentity-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    location: location
    name: nameConvResTypeAtEnd
      ? 'avd-image-builder-${locations[varLocation].abbreviation}-${resourceAbbreviations.userAssignedIdentities}'
      : '${resourceAbbreviations.userAssignedIdentities}-avd-image-builder-${locations[varLocation].abbreviation}'
    tags: tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
  }
  dependsOn: [
    imageBuildRg
  ]
}

resource existingUserAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(userAssignedIdentityResourceId)) {
  scope: resourceGroup(split(userAssignedIdentityResourceId, '/')[2], split(userAssignedIdentityResourceId, '/')[4])
  name: last(split(userAssignedIdentityResourceId, '/'))
}

// * Image Definition * //

resource existingImageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' existing = if (!empty(imageDefinitionResourceId)) {
  name: !empty(imageDefinitionResourceId)
    ? '${split(imageDefinitionResourceId, '/')[8]}/${last(split(imageDefinitionResourceId, '/'))}'
    : 'placeholder/placeholder'
  scope: resourceGroup(
    !empty(imageDefinitionResourceId) ? split(imageDefinitionResourceId, '/')[2] : subscription().subscriptionId,
    !empty(imageDefinitionResourceId) ? split(imageDefinitionResourceId, '/')[4] : 'placeholder'
  )
}

module imageDefinition '../../.common/bicepModules/compute/galleries/images/deploy.bicep' = if (empty(imageDefinitionResourceId)) {
  name: '${depPrefix}Gallery-Image-Definition-${deploymentSuffix}'
  scope: resourceGroup(split(computeGalleryResourceId, '/')[2], split(computeGalleryResourceId, '/')[4])
  params: {
    location: location
    features: imageDefinitionFeatures
    galleryName: last(split(computeGalleryResourceId, '/'))
    name: galleryImageDefinitionName
    hyperVGeneration: galleryImageDefinitionHyperVGeneration
    osType: 'Windows'
    osState: 'Generalized'
    publisher: effectiveGalleryImageDefinitionPublisher
    offer: effectiveGalleryImageDefinitionOffer
    sku: effectiveGalleryImageDefinitionSku
    tags: tags[?'Microsoft.Compute/galleries/images'] ?? {}
  }
}

resource remoteComputeGallery 'Microsoft.Compute/galleries@2024-03-03' existing = if (!empty(remoteComputeGalleryResourceId)) {
  name: last(split(remoteComputeGalleryResourceId, '/'))
  scope: resourceGroup(split(remoteComputeGalleryResourceId, '/')[2], split(remoteComputeGalleryResourceId, '/')[4])
}

module remoteImageDefinition '../../.common/bicepModules/compute/galleries/images/deploy.bicep' = if (!empty(remoteComputeGalleryResourceId)) {
  name: '${depPrefix}Remote-Gallery-Image-Definition-${deploymentSuffix}'
  scope: resourceGroup(split(remoteComputeGalleryResourceId, '/')[2], split(remoteComputeGalleryResourceId, '/')[4])
  params: {
    galleryName: last(split(remoteComputeGalleryResourceId, '/'))
    location: remoteLocation
    name: empty(imageDefinitionResourceId) ? galleryImageDefinitionName : last(split(imageDefinitionResourceId, '/'))
    features: imageDefinitionFeatures
    hyperVGeneration: empty(imageDefinitionResourceId)
      ? galleryImageDefinitionHyperVGeneration
      : any(existingImageDefinition!.properties.hyperVGeneration)
    osType: 'Windows'
    osState: 'Generalized'
    publisher: empty(imageDefinitionResourceId)
      ? effectiveGalleryImageDefinitionPublisher
      : existingImageDefinition!.properties.identifier.publisher
    offer: empty(imageDefinitionResourceId)
      ? effectiveGalleryImageDefinitionOffer
      : existingImageDefinition!.properties.identifier.offer
    sku: empty(imageDefinitionResourceId)
      ? effectiveGalleryImageDefinitionSku
      : existingImageDefinition!.properties.identifier.sku
    tags: tags[?'Microsoft.Compute/galleries/images'] ?? {}
  }
}

// * Role Assignments * //

module roleAssignmentContributorBuildRg '../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  name: '${depPrefix}RA-MI-VirtMachContr-BuildRG-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    principalId: empty(userAssignedIdentityResourceId)
      ? userAssignedIdentity!.outputs.principalId
      : existingUserAssignedIdentity!.properties.principalId
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' // Virtual Machine Contributor
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    imageBuildRg
  ]
}

module roleAssignmentBlobDataContributorExistingStorage '../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (collectCustomizationLogs && !empty(logStorageAccountResourceId) && empty(userAssignedIdentityResourceId)) {
  // Only needed when imageBuild creates its own UAI — when the imageManagement UAI is supplied via
  // userAssignedIdentityResourceId it already has Blob Data Contributor granted by imageManagement.
  name: '${depPrefix}RA-MI-StorBlobDataContr-ExistingLogsRG-${deploymentSuffix}'
  scope: resourceGroup(split(logStorageAccountResourceId, '/')[2], split(logStorageAccountResourceId, '/')[4])
  params: {
    principalId: userAssignedIdentity!.outputs.principalId
    roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
  }
}

// * Orchestration VM * //

module orchestrationVm '../../.common/bicepModules/compute/virtualMachines/deploy.bicep' = {
  name: '${depPrefix}Orchestration-VM-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    location: computeLocation
    name: orchestrationVmName
    nicName: '${orchestrationVmName}-nic'
    osDiskName: '${orchestrationVmName}-osdisk'
    adminPassword: adminPw
    adminUsername: adminUserName
    enableAcceleratedNetworking: vmAcceleratedNetworking
    encryptionAtHost: encryptionAtHost
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2019-datacenter-core-g2'
    licenseType: 'Windows_Server'
    diskControllerType: vmDiskControllerType
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    subnetResourceId: subnetResourceId
    tags: tags[?'Microsoft.Compute/virtualMachines'] ?? {}
    userAssignedIdentityResourceIds: [
      empty(userAssignedIdentityResourceId) ? userAssignedIdentity!.outputs.resourceId : userAssignedIdentityResourceId
    ]
    vmSize: vmSize
  }
  dependsOn: [
    imageBuildRg
  ]
}

// * Image VM * //

module imageVm '../../.common/bicepModules/compute/virtualMachines/deploy.bicep' = {
  name: '${depPrefix}Image-VM-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    hibernationEnabled: !empty(filter(imageDefinitionFeatures, feature => feature.name == 'IsHibernateSupported'))
      ? bool(filter(imageDefinitionFeatures, feature => feature.name == 'IsHibernateSupported')[0]!.value)
      : false
    location: computeLocation
    name: imageVmName
    nicName: '${imageVmName}-nic'
    osDiskName: '${imageVmName}-osdisk'
    adminPassword: adminPw
    adminUsername: adminUserName
    customImageResourceId: customSourceImageResourceId
    imagePublisher: mpPublisher
    imageOffer: mpOffer
    imageSku: mpSku
    osDiskSku: 'Premium_LRS'
    osDiskSizeGB: diskSizeGB
    diskControllerType: vmDiskControllerType
    encryptionAtHost: encryptionAtHost
    enableAcceleratedNetworking: vmAcceleratedNetworking
    securityType: vmSecurityType
    secureBootEnabled: vmSecurityType == 'TrustedLaunch' ? true : false
    vTpmEnabled: vmSecurityType == 'TrustedLaunch' ? true : false
    // For CVM builds, prefer the CVM DES on the image VM OS disk; fall back to the standard gallery DES when no CVM DES is provided
    // (e.g. when EncryptedWithPmk guest state is selected but a policy requires a DES on all VM disks).
    // For all other builds, apply the standard gallery DES.
    diskEncryptionSetResourceId: vmSecurityType == 'ConfidentialVM'
      ? (!empty(effectiveConfidentialVmDiskEncryptionSetResourceId)
          ? effectiveConfidentialVmDiskEncryptionSetResourceId
          : diskEncryptionSetResourceId)
      : diskEncryptionSetResourceId
    subnetResourceId: subnetResourceId
    tags: tags[?'Microsoft.Compute/virtualMachines'] ?? {}
    userAssignedIdentityResourceIds: [
      empty(userAssignedIdentityResourceId) ? userAssignedIdentity!.outputs.resourceId : userAssignedIdentityResourceId
    ]
    vmSize: vmSize
  }
  dependsOn: [
    imageBuildRg
  ]
}

// * Resize OS Disk Partition * //

module resizeDisk '../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = if (diskSizeGB != 0 && diskSizeGB != 128) {
  name: '${depPrefix}Resize-ImageVM-OSDisk-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    location: computeLocation
    name: 'ResizeDisk'
    virtualMachineName: imageVm.outputs.name
    script: loadTextContent('../../.common/scripts/Resize-Disk.ps1')
    treatFailureAsDeploymentFailure: true
  }
}

// * Image Customizations * //

module customizeImage 'modules/customizeImage.bicep' = {
  name: '${depPrefix}Customize-Image-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    cloud: cloud
    appsToRemove: appsToRemove
    location: computeLocation
    cleanupDesktop: cleanupDesktop
    customizations: uniqueCustomizers
    installFsLogix: installFsLogix
    installOneDrive: installOneDrive
    installTeams: installTeams
    applyWindowsDesktopOptimizations: applyWindowsDesktopOptimizations
    disableSoftwareUpdates: disableSoftwareUpdates
    userAssignedIdentityClientId: empty(userAssignedIdentityResourceId)
      ? userAssignedIdentity!.outputs.clientId
      : existingUserAssignedIdentity!.properties.clientId
    orchestrationVmName: orchestrationVm.outputs.name
    office365AppsToInstall: office365AppsToInstall
    imageVmName: imageVm.outputs.name
    teamsCloudType: teamsCloudType
    logBlobContainerUri: logContainerUri
    installUpdates: installUpdates
    updateUwpApps: updateUwpApps
    updateService: updateService
    wsusServer: wsusServer
    artifactsContainerUri: artifactsContainerUri
    downloads: downloads
    downloadLatestMicrosoftContent: downloadLatestMicrosoftContent
    vdiCustomizations: uniqueVdiCustomizers
  }
  dependsOn: [
    resizeDisk
  ]
}

// * VM Generalization * //

module generalizeImageVM 'modules/generalizeVm.bicep' = {
  name: '${depPrefix}Generalize-ImageVM-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    adminPw: adminPw
    deploymentSuffix: deploymentSuffix
    imageVmName: imageVm.outputs.name
    location: location
    logBlobContainerUri: logContainerUri
    orchestrationVmName: orchestrationVm.outputs.name
    userAssignedIdentityClientId: empty(userAssignedIdentityResourceId)
      ? userAssignedIdentity!.outputs.clientId
      : existingUserAssignedIdentity!.properties.clientId
  }
  dependsOn: [
    customizeImage
  ]
}

// * Capture Image * //

module captureImage 'modules/captureImage.bicep' = {
  name: '${depPrefix}Capture-Image-${deploymentSuffix}'
  params: {
    computeGalleryResourceId: computeGalleryResourceId
    depPrefix: depPrefix
    hyperVGeneration: galleryImageDefinitionHyperVGeneration
    imageBuildResourceGroupName: imageBuildResourceGroupName
    imageDefinitionSecurityType: effectiveGalleryImageDefinitionSecurityType
    imageName: !empty(imageDefinitionResourceId)
      ? last(split(imageDefinitionResourceId, '/'))
      : imageDefinition!.outputs.name
    imageVersionDefaultReplicaCount: imageVersionDefaultReplicaCount
    imageVersionDefaultStorageAccountType: imageVersionDefaultStorageAccountType
    imageVersionExcludeFromLatest: imageVersionExcludeFromLatest
    imageVersionName: imageVersionName
    imageVersionReplicationRegions: imageVersionReplicationRegionsWithEncryption
    imageVersionEndOfLifeDate: imageVersionEndOfLifeDate
    location: computeLocation
    tags: tags
    deploymentSuffix: deploymentSuffix
    diskEncryptionSetId: diskEncryptionSetResourceId
    confidentialVMEncryptionType: galleryImageVersionConfidentialVMEncryptionType
    secureVMDiskEncryptionSetId: effectiveConfidentialVmDiskEncryptionSetResourceId
    virtualMachineResourceId: imageVm.outputs.resourceId
  }
  dependsOn: [
    generalizeImageVM
  ]
}

// * Cleanup Temporary Resources * //

module removeImageBuildResources '../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: '${depPrefix}Remove-Image-Image-Build-Resources-${deploymentSuffix}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    asyncExecution: true
    location: computeLocation
    name: 'RemoveImageBuildResources'
    virtualMachineName: orchestrationVm.outputs.name
    script: loadTextContent('../../.common/scripts/Remove-ImageBuildResources.ps1')
    treatFailureAsDeploymentFailure: false
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      {
        name: 'UserAssignedIdentityClientId'
        value: empty(userAssignedIdentityResourceId)
          ? userAssignedIdentity!.outputs.clientId
          : existingUserAssignedIdentity!.properties.clientId
      }
      {
        name: 'ImageResourceId'
        value: contains(effectiveGalleryImageDefinitionSecurityType, 'Supported')
          ? captureImage.outputs.managedImageId
          : ''
      }
      { name: 'ImageVmResourceId', value: imageVm.outputs.resourceId }
      { name: 'ManagementVmResourceId', value: orchestrationVm.outputs.resourceId }
    ]
  }
}

module remoteImageVersion '../../.common/bicepModules/compute/galleries/images/versions/deploy.bicep' = if (!empty(remoteComputeGalleryResourceId)) {
  name: '${depPrefix}Remote-ImageVersion-${deploymentSuffix}'
  scope: resourceGroup(split(remoteComputeGalleryResourceId, '/')[2], split(remoteComputeGalleryResourceId, '/')[4])
  params: {
    location: location
    name: imageVersionName
    galleryName: last(split(remoteComputeGalleryResourceId, '/'))
    imageDefinitionName: remoteImageDefinition!.outputs.name
    endOfLifeDate: imageVersionEndOfLifeDate
    excludeFromLatest: remoteImageVersionExcludeFromLatest
    replicaCount: remoteImageVersionDefaultReplicaCount
    storageAccountType: remoteImageVersionStorageAccountType
    sourceId: captureImage.outputs.imageVersionId
    tags: tags[?'Microsoft.Compute/galleries/images/versions'] ?? {}
  }
}

output imageDefinitionId string = empty(imageDefinitionResourceId)
  ? imageDefinition!.outputs.resourceId
  : imageDefinitionResourceId

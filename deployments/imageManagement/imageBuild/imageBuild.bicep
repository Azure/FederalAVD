targetScope = 'subscription'

metadata name = 'Zero Trust Architecture Custom Windows Image Builder'
metadata description = 'This solution allows you to create a custom image much like Azure VM Image Builder, but utilizes zero trust architecture and does not require that service.'
metadata author = 'shawn.meyer@microsoft.com'

@description('Value appended to the deployment names.')
param timeStamp string = utcNow()

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
param vmSize string

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

@description('Optional. Apply the Virtual Desktop Optimization Tool customizations.')
param installVirtualDesktopOptimizationTool bool = false

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

@description('Optional. Log Storage Account Network Access Configuration.')
@allowed([
  'PrivateEndpoint'
  'PublicEndpoint'
  'ServiceEndpoint'
])
param logStorageAccountNetworkAccess string = 'PublicEndpoint'

@description('Optional. Determines if the latest updates from the specified update service will be installed.')
param installUpdates bool = true

@allowed([
  'WU'
  'MU'
  'WSUS'
  'DCAT'
  'STORE'
  'OTHER'
])
@description('Optional. The update service.')
param updateService string = 'MU'

@description('Conditional. The WSUS Server Url if WSUS is specified. (i.e., https://wsus.corp.contoso.com:8531)')
param wsusServer string = ''

@description('''Optional. The resource id of the existing Azure storage account blob service private dns zone.
Used for the Customization Logs Storage Account.
This zone must be linked to or resolvable from the vnet referenced in the [privateEndpointSubnetResourceId] parameter.''')
param blobPrivateDnsZoneResourceId string = ''

@description('Optional. The resource id of the private endpoint subnet. Used for the Customization Logs Storage Account.')
param privateEndpointSubnetResourceId string = ''

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
param imageDefinitionIsAcceleratedNetworkSupported bool = false

@description('Optional. Specifies whether the image definition supports creating VMs with support for hibernation.')
param imageDefinitionIsHibernateSupported bool = false

@description('Optional. Specifies whether the image definition supports capturing images of NVMe disks or Virtual Machines.')
param imageDefinitionIsHigherStoragePerformanceSupported bool = false

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

var installers = []
// elimnate duplicates
var customizers = union(customizations, installers)

var cloud = toLower(environment().name)

var locations = loadJsonContent('../../../.common/data/locations.json')[environment().name]
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')
var downloads = startsWith(cloud, 'usn')
  ? loadJsonContent('../parameters/topsecret.downloads.parameters.json')
  : startsWith(cloud, 'uss')
      ? loadJsonContent('../parameters/secret.downloads.parameters.json')
      : loadJsonContent('../parameters/public.downloads.parameters.json')

var computeLocation = vnet.location
var depPrefix = !empty(deploymentPrefix) ? '${deploymentPrefix}-' : ''
var logStorageAccountName = take(
  replace(toLower('sa${depPrefix}log${uniqueString(subscription().id,imageBuildResourceGroupName)}'), '-', ''),
  24
)

var vnetName = !empty(privateEndpointSubnetResourceId) ? split(privateEndpointSubnetResourceId, '/')[8] : ''
var privateEndpointNameConv = replace(
  '${nameConvResTypeAtEnd ? 'RESOURCE-SUBRESOURCE-${vnetName}-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-${vnetName}'}',
  'RESOURCETYPE',
  resourceAbbreviations.privateEndpoints
)
var privateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  logStorageAccountName
)
var customNetworkInterfaceName = nameConvResTypeAtEnd
  ? '${privateEndpointName}-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${privateEndpointName}'

var imageBuildResourceGroupName = empty(imageBuildResourceGroupId)
  ? (empty(customBuildResourceGroupName)
      ? nameConvResTypeAtEnd
          ? 'avd-image-builds-${locations[location].abbreviation}-${resourceAbbreviations.resourceGroups}'
          : '${resourceAbbreviations.resourceGroups}-avd-image-builds-${locations[location].abbreviation}'
      : customBuildResourceGroupName)
  : last(split(imageBuildResourceGroupId, '/'))

var adminPw = '1qaz@WSX1qaz@WSX'
//var adminPw = '1qaz@WSX${uniqueString(subscription().id, imageBuildResourceGroupName)}'
var adminUserName = 'vmadmin'

var logContainerName = 'image-customization-logs'
var logContainerUri = collectCustomizationLogs
  ? '${logsStorageAccount.outputs.primaryBlobEndpoint}${logContainerName}/'
  : ''

var imageDefinitionFeatures = empty(imageDefinitionResourceId)
  ? [
      union(
        imageDefinitionIsHibernateSupported ? { name: 'IsHibernateSupported', value: 'True' } : {},
        imageDefinitionIsAcceleratedNetworkSupported ? { name: 'IsAcceleratedNetworkSupported', value: 'True' } : {},
        imageDefinitionIsHigherStoragePerformanceSupported ? { name: 'DiskControllerTypes', value: 'SCSI, NVMe' } : {},
        imageDefinitionSecurityType != 'Standard' ? { name: 'SecurityType', value: imageDefinitionSecurityType } : {}
      )
    ]
  : existingImageDefinition.properties.features

var galleryImageDefinitionHyperVGeneration = endsWith(mpSku, 'g2') || startsWith(mpSku, 'win11') ? 'V2' : 'V1'
var galleryImageDefinitionName = empty(imageDefinitionResourceId)
  ? empty(customImageDefinitionName)
      ? nameConvResTypeAtEnd
          ? replace(
              '${replace(galleryImageDefinitionPublisher, '-', '')}-${replace(galleryImageDefinitionOffer, '-', '')}-${replace(galleryImageDefinitionSku, '-', '')}-${resourceAbbreviations.imageDefinitions}',
              ' ',
              ''
            )
          : replace(
              '${resourceAbbreviations.imageDefinitions}-${replace(galleryImageDefinitionPublisher, '-', '')}-${replace(galleryImageDefinitionOffer, '-', '')}-${replace(galleryImageDefinitionSku, '-', '')}',
              ' ',
              ''
            )
      : customImageDefinitionName
  : last(split(imageDefinitionResourceId, '/'))
var galleryImageDefinitionOffer = !empty(imageDefinitionOffer) ? replace(imageDefinitionOffer, ' ', '') : mpOffer
var galleryImageDefinitionPublisher = !empty(imageDefinitionPublisher)
  ? replace(imageDefinitionPublisher, ' ', '')
  : mpPublisher

var galleryImageDefinitionSecurityType = empty(imageDefinitionResourceId)
  ? imageDefinitionSecurityType
  : !empty(filter(existingImageDefinition.properties.features, feature => feature.name == 'SecurityType'))
      ? filter(existingImageDefinition.properties.features, feature => feature.name == 'SecurityType')[0].value
      : 'Standard'
var galleryImageDefinitionSku = !empty(imageDefinitionSku) ? replace(imageDefinitionSku, ' ', '') : mpSku
// build an image version from the ISO 8601 timestamp
var autoImageVersionName = '${substring(timeStamp, 0, 4)}.${substring(timeStamp, 4, 4)}.${substring(timeStamp, 9, 4)}'
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

var imageVersionEndOfLifeDate = imageVersionEOLinDays > 0 ? dateTimeAdd(timeStamp, 'P${imageVersionEOLinDays}D') : ''

var imageVmName = take('${depPrefix}vmimg-${uniqueString(timeStamp)}', 15)
var orchestrationVmName = take('${depPrefix}vmorc-${uniqueString(timeStamp)}', 15)

var vmSecurityType = galleryImageDefinitionSecurityType == 'TrustedLaunch'
  ? 'TrustedLaunch'
  : galleryImageDefinitionSecurityType == 'ConfidentialVM' ? 'ConfidentialVM' : 'Standard'

var remoteLocation = !empty(remoteComputeGalleryResourceId) ? remoteComputeGallery.location : ''

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

module userAssignedIdentity '../../sharedModules/resources/managed-identity/user-assigned-identity/main.bicep' = if (empty(userAssignedIdentityResourceId)) {
  name: '${depPrefix}ManagedIdentity-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    location: location
    name: nameConvResTypeAtEnd
      ? 'avd-image-builder-${locations[location].abbreviation}-${resourceAbbreviations.userAssignedIdentities}'
      : '${resourceAbbreviations.userAssignedIdentities}-image-builder-${locations[location].abbreviation}'
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
  name: '${split(imageDefinitionResourceId, '/')[8]}/${last(split(imageDefinitionResourceId, '/'))}'
  scope: resourceGroup(split(imageDefinitionResourceId, '/')[2], split(imageDefinitionResourceId, '/')[4])
}

module imageDefinition '../../sharedModules/resources/compute/gallery/image/main.bicep' = if (empty(imageDefinitionResourceId)) {
  name: '${depPrefix}Gallery-Image-Definition-${timeStamp}'
  scope: resourceGroup(split(computeGalleryResourceId, '/')[4])
  params: {
    location: location
    features: imageDefinitionFeatures
    galleryName: last(split(computeGalleryResourceId, '/'))
    name: galleryImageDefinitionName
    hyperVGeneration: galleryImageDefinitionHyperVGeneration
    osType: 'Windows'
    osState: 'Generalized'
    publisher: galleryImageDefinitionPublisher
    offer: galleryImageDefinitionOffer
    sku: galleryImageDefinitionSku
    tags: tags[?'Microsoft.Compute/galleries/images'] ?? {}
  }
}

resource remoteComputeGallery 'Microsoft.Compute/galleries@2024-03-03' existing = if (!empty(remoteComputeGalleryResourceId)) {
  name: last(split(remoteComputeGalleryResourceId, '/'))
  scope: resourceGroup(split(remoteComputeGalleryResourceId, '/')[2], split(remoteComputeGalleryResourceId, '/')[4])
}

module remoteImageDefinition '../../sharedModules/resources/compute/gallery/image/main.bicep' = if (!empty(remoteComputeGalleryResourceId)) {
  name: '${depPrefix}Remote-Gallery-Image-Definition-${timeStamp}'
  scope: resourceGroup(split(remoteComputeGalleryResourceId, '/')[2], split(remoteComputeGalleryResourceId, '/')[4])
  params: {
    galleryName: last(split(remoteComputeGalleryResourceId, '/'))
    location: remoteLocation
    name: empty(imageDefinitionResourceId) ? galleryImageDefinitionName : last(split(imageDefinitionResourceId, '/'))
    features: imageDefinitionFeatures
    hyperVGeneration: empty(imageDefinitionResourceId)
      ? galleryImageDefinitionHyperVGeneration
      : any(existingImageDefinition.properties.hyperVGeneration)
    osType: 'Windows'
    osState: 'Generalized'
    publisher: empty(imageDefinitionResourceId)
      ? galleryImageDefinitionPublisher
      : existingImageDefinition.properties.identifier.publisher
    offer: empty(imageDefinitionResourceId)
      ? galleryImageDefinitionOffer
      : existingImageDefinition.properties.identifier.offer
    sku: empty(imageDefinitionResourceId)
      ? galleryImageDefinitionSku
      : existingImageDefinition.properties.identifier.sku
    tags: tags[?'Microsoft.Compute/galleries/images'] ?? {}
  }
}

// * Role Assignments * //

module roleAssignmentContributorBuildRg '../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = {
  name: '${depPrefix}RoleAssign-MI-VirtMachContr-BuildRG-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    principalId: empty(userAssignedIdentityResourceId)
      ? userAssignedIdentity.outputs.principalId
      : existingUserAssignedIdentity.properties.principalId
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' // Virtual Machine Contributor
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    imageBuildRg
  ]
}

module roleAssignmentBlobDataContributorBuilderRg '../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = if (collectCustomizationLogs) {
  name: '${depPrefix}RoleAssign-MI-StorageBlobDataContr-BuildRG-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    principalId: empty(userAssignedIdentityResourceId)
      ? userAssignedIdentity.outputs.principalId
      : existingUserAssignedIdentity.properties.principalId
    roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
  }
}

// * Logging * //

module logsStorageAccount '../../sharedModules/resources/storage/storage-account/main.bicep' = if (collectCustomizationLogs) {
  name: '${depPrefix}Logs-StorageAccount-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    #disable-next-line BCP335
    name: logStorageAccountName
    location: computeLocation
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    requireInfrastructureEncryption: true
    blobServices: {
      containers: [
        {
          name: logContainerName
          publicAccess: 'None'
        }
      ]
    }
    kind: 'StorageV2'
    managementPolicyRules: [
      {
        enabled: true
        name: 'Delete Blobs after 7 days'
        type: 'Lifecycle'
        definition: {
          actions: {
            baseBlob: {
              delete: {
                daysAfterModificationGreaterThan: 7
              }
            }
          }
          filters: {
            blobTypes: [
              'blockBlob'
              'appendBlob'
            ]
          }
        }
      }
    ]
    privateEndpoints: logStorageAccountNetworkAccess == 'PrivateEndpoint' && !empty(privateEndpointSubnetResourceId)
      ? [
          {
            name: privateEndpointName
            customNetworkInterfaceName: customNetworkInterfaceName
            privateDnsZoneGroup: empty(blobPrivateDnsZoneResourceId)
              ? null
              : {
                  privateDNSResourceIds: ['${blobPrivateDnsZoneResourceId}']
                }
            service: 'blob'
            subnetResourceId: privateEndpointSubnetResourceId
            tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
          }
        ]
      : null
    publicNetworkAccess: logStorageAccountNetworkAccess == 'PrivateEndpoint' ? 'Disabled' : 'Enabled'
    networkAcls: logStorageAccountNetworkAccess == 'PrivateEndpoint'
      ? {
          bypass: 'None'
          defaultAction: 'Deny'
        }
      : logStorageAccountNetworkAccess == 'ServiceEndpoint'
          ? {
              bypass: 'None'
              defaultAction: 'Deny'
              ipRules: []
              virtualNetworkRules: [
                {
                  id: subnetResourceId
                  action: 'Allow'
                }
              ]
            }
          : {
              bypass: 'None'
              defaultAction: 'Allow'
            }
    sasExpirationPeriod: '180.00:00:00'
    skuName: 'Standard_LRS'
    tags: tags[?'Microsoft.Storage/storageAccounts'] ?? {}
  }
  dependsOn: [
    imageBuildRg
  ]
}

// * Orchestration VM * //

module orchestrationVm '../../sharedModules/resources/compute/virtual-machine/main.bicep' = {
  name: '${depPrefix}Orchestration-VM-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    location: computeLocation
    name: orchestrationVmName
    adminPassword: adminPw
    adminUsername: adminUserName
    encryptionAtHost: encryptionAtHost
    imageReference: {
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2019-datacenter-core-g2'
      version: 'latest'
    }
    nicConfigurations: [
      {
        deleteOption: 'Delete'
        enableAcceleratedNetworking: false
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetResourceId
          }
        ]
        nicSuffix: '-nic-01'
      }
    ]
    osDisk: {
      caching: 'ReadWrite'
      createOption: 'fromImage'
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
    }
    osType: 'Windows'
    tags: tags[?'Microsoft.Compute/virtualMachines'] ?? {}
    userAssignedIdentities: empty(userAssignedIdentityResourceId)
      ? {
          '${userAssignedIdentity.outputs.resourceId}': {}
        }
      : {
          '${userAssignedIdentityResourceId}': {}
        }
    vmSize: 'Standard_B2s'
  }
  dependsOn: [
    imageBuildRg
    roleAssignmentContributorBuildRg
  ]
}

// * Image VM * //

module imageVm '../../sharedModules/resources/compute/virtual-machine/main.bicep' = {
  name: '${depPrefix}Image-VM-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    hibernationEnabled: !empty(filter(imageDefinitionFeatures, feature => feature.name == 'IsHibernateSupported'))
      ? bool(filter(imageDefinitionFeatures, feature => feature.name == 'IsHibernateSupported')[0].value)
      : false
    location: computeLocation
    name: imageVmName
    adminPassword: adminPw
    adminUsername: adminUserName
    bootDiagnostics: false
    diskControllerType: !empty(filter(imageDefinitionFeatures, feature => feature.name == 'DiskControllerTypes'))
      ? contains(filter(imageDefinitionFeatures, feature => feature.name == 'DiskControllerTypes')[0].value, 'NVMe')
          ? 'NVMe'
          : 'SCSI'
      : 'SCSI'
    encryptionAtHost: encryptionAtHost
    imageReference: empty(customSourceImageResourceId)
      ? {
          publisher: mpPublisher
          offer: mpOffer
          sku: mpSku
          version: 'latest'
        }
      : {
          id: customSourceImageResourceId
        }
    nicConfigurations: [
      {
        enableAcceleratedNetworking: !empty(filter(
            imageDefinitionFeatures,
            feature => feature.name == 'IsAcceleratedNetworkSupported'
          ))
          ? bool(filter(imageDefinitionFeatures, feature => feature.name == 'IsAcceleratedNetworkSupported')[0].value)
          : false
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetResourceId
          }
        ]
        nicSuffix: '-nic-01'
      }
    ]
    osDisk: {
      caching: 'ReadWrite'
      createOption: 'fromImage'
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    osType: 'Windows'
    securityType: vmSecurityType
    secureBootEnabled: vmSecurityType == 'TrustedLaunch' ? true : false
    vTpmEnabled: vmSecurityType == 'TrustedLaunch' ? true : false
    tags: tags[?'Microsoft.Compute/virtualMachines'] ?? {}
    userAssignedIdentities: empty(userAssignedIdentityResourceId)
      ? {
          '${userAssignedIdentity.outputs.resourceId}': {}
        }
      : {
          '${userAssignedIdentityResourceId}': {}
        }
    vmSize: vmSize
  }
  dependsOn: [
    imageBuildRg
  ]
}

// * Image Customizations * //

module customizeImage 'modules/customizeImage.bicep' = {
  name: '${depPrefix}Customize-Image-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    adminPw: adminPw
    adminUserName: adminUserName
    cloud: cloud
    appsToRemove: appsToRemove
    location: computeLocation
    cleanupDesktop: cleanupDesktop
    customizations: customizers
    installFsLogix: installFsLogix
    installOneDrive: installOneDrive
    installTeams: installTeams
    installVirtualDesktopOptimizationTool: installVirtualDesktopOptimizationTool
    userAssignedIdentityClientId: empty(userAssignedIdentityResourceId)
      ? userAssignedIdentity.outputs.clientId
      : existingUserAssignedIdentity.properties.clientId
    orchestrationVmName: orchestrationVm.outputs.name
    office365AppsToInstall: office365AppsToInstall
    imageVmName: imageVm.outputs.name
    teamsCloudType: teamsCloudType
    logBlobContainerUri: logContainerUri
    installUpdates: installUpdates
    updateService: updateService
    wsusServer: wsusServer
    artifactsContainerUri: artifactsContainerUri
    downloads: downloads
    downloadLatestMicrosoftContent: downloadLatestMicrosoftContent
    vdiCustomizations: vdiCustomizations
  }
}

// * VM Generalization * //

module stopAndGeneralizeImageVM '../../sharedModules/resources/compute/virtual-machine/runCommand/main.bicep' = {
  name: '${depPrefix}Generalize-VM-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    location: computeLocation
    name: 'StopAndGeneralize'
    parameters: [
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: empty(userAssignedIdentityResourceId)
          ? userAssignedIdentity.outputs.clientId
          : existingUserAssignedIdentity.properties.clientId
      }
      {
        name: 'VmResourceId'
        value: imageVm.outputs.resourceId
      }
    ]
    script: loadTextContent('../../../.common/scripts/Generalize-Vm.ps1')
    treatFailureAsDeploymentFailure: true
    virtualMachineName: orchestrationVm.outputs.name
  }
  dependsOn: [
    customizeImage
  ]
}

// * Capture Image * //

module captureImage 'modules/captureImage.bicep' = {
  name: '${depPrefix}Capture-Image-${timeStamp}'
  params: {
    computeGalleryResourceId: computeGalleryResourceId
    depPrefix: depPrefix
    hyperVGeneration: galleryImageDefinitionHyperVGeneration
    imageBuildResourceGroupName: imageBuildResourceGroupName
    imageDefinitionSecurityType: galleryImageDefinitionSecurityType
    imageName: !empty(imageDefinitionResourceId)
      ? last(split(imageDefinitionResourceId, '/'))
      : imageDefinition.outputs.name
    imageVersionDefaultReplicaCount: imageVersionDefaultReplicaCount
    imageVersionDefaultStorageAccountType: imageVersionDefaultStorageAccountType
    imageVersionExcludeFromLatest: imageVersionExcludeFromLatest
    imageVersionName: imageVersionName
    imageVersionReplicationRegions: imageVersionReplicationRegions
    imageVersionEndOfLifeDate: imageVersionEndOfLifeDate
    location: computeLocation
    tags: tags
    timeStamp: timeStamp
    virtualMachineResourceId: imageVm.outputs.resourceId
  }
  dependsOn: [
    stopAndGeneralizeImageVM
  ]
}

// * Cleanup Temporary Resources * //

module removeImageBuildResources '../../sharedModules/resources/compute/virtual-machine/runCommand/main.bicep' = {
  name: '${depPrefix}Remove-Image-Image-Build-Resources-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    asyncExecution: true
    location: computeLocation
    name: 'RemoveImageBuildResources'
    parameters: [
      {
        name: 'ResourceManagerUri'
        value: environment().resourceManager
      }
      {
        name: 'UserAssignedIdentityClientId'
        value: empty(userAssignedIdentityResourceId)
          ? userAssignedIdentity.outputs.clientId
          : existingUserAssignedIdentity.properties.clientId
      }
      {
        name: 'ImageResourceId'
        value: contains(galleryImageDefinitionSecurityType, 'Supported') ? captureImage.outputs.managedImageId : ''
      }
      {
        name: 'ImageVmResourceId'
        value: imageVm.outputs.resourceId
      }
      {
        name: 'ManagementVmResourceId'
        value: orchestrationVm.outputs.resourceId
      }
    ]
    script: loadTextContent('../../../.common/scripts/Remove-ImageBuildResources.ps1')
    treatFailureAsDeploymentFailure: false
    virtualMachineName: orchestrationVm.outputs.name
  }
}

module remoteImageVersion '../../sharedModules/resources/compute/gallery/image/version/main.bicep' = if (!empty(remoteComputeGalleryResourceId)) {
  name: '${depPrefix}Remote-ImageVersion-${timeStamp}'
  scope: resourceGroup(split(remoteComputeGalleryResourceId, '/')[2], split(remoteComputeGalleryResourceId, '/')[4])
  params: {
    location: location
    name: imageVersionName
    galleryName: last(split(remoteComputeGalleryResourceId, '/'))
    imageName: remoteImageDefinition.outputs.name
    endOfLifeDate: imageVersionEndOfLifeDate
    excludeFromLatest: remoteImageVersionExcludeFromLatest
    replicaCount: remoteImageVersionDefaultReplicaCount
    storageAccountType: remoteImageVersionStorageAccountType
    sourceId: captureImage.outputs.imageVersionId
    tags: tags[?'Microsoft.Compute/galleries/images/versions'] ?? {}
  }
}

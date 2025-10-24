targetScope = 'subscription'

@minLength(3)
@maxLength(63)
@description('Optional. Blob Container Name. Must start with a letter. Can only contain lower case letters, numbers, and -.')
param artifactsContainerName string = 'artifacts'

param location string = deployment().location

@description('Optional. Custom workload identifier to use when naming the resource group and resources. If not specified then "image-management" will be used. All resources will be created using the Cloud Adoption Framework naming convention.')
param customIdentifier string = ''

@description('Optional. Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name.')
param nameConvResTypeAtEnd bool = false

@description('Optional. Resource Id of an existing Log Analytics Workspace to which diagnostic logs will be sent.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Remote Location to which an Image Gallery will be deployed to support regional disaster recovery.')
param remoteLocation string = ''

@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
@description('Optional. Storage Account Sku Name.')
param storageSkuName string = 'Standard_LRS'

@allowed([
  'Premium'
  'Hot'
  'Cool'
])
@description('Conditional. Required if the Storage Account kind is set to BlobStorage. The access tier is used for billing. The "Premium" access tier is the default value for premium block blobs storage account type and it cannot be changed for the premium block blobs storage account type.')
param storageAccessTier string = 'Hot'

@description('Optional. Indicates whether the storage account permits requests to be authorized with the account access key via Shared Key. If false, then all requests, including shared access signatures, must be authorized with Azure Active Directory (Azure AD). The default value is null, which is equivalent to true.')
param storageAllowSharedKeyAccess bool = true

@description('Optional. The SAS expiration period. DD.HH:MM:SS.')
param storageSASExpirationPeriod string = '180.00:00:00'

@description('Optional. The Resource Id of the Private DNS Zone where the Private Endpoint (if configured) A record will be registered.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Optional. Whether or not public network access is allowed for this resource. To limit public network access, use the "PermittedIPs" and/or the "ServiceEndpointSubnetResourceIds" parameters.')
@allowed([
  'Enabled'
  'Disabled'
])
param storagePublicNetworkAccess string = 'Enabled'

@description('Optional. The ResourceId of the private endpoint subnet.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Array of permitted IPs or IP CIDR blocks that can access the storage account using the Public Endpoint.')
param storagePermittedIPs array = []

@description('Optional. An array of subnet resource IDs where Service Endpoints will be created to allow access to the storage account through the public endpoint.')
param storageServiceEndpointSubnetResourceIds array = []

@description('Optional. The tags by resource type to apply to the resources created by this template.')
/*
tags = {
  'Microsoft.Compute/computeGalleries': {
    'Purpose': 'Image Management'
  },
  'Microsoft.Storage/storageAccounts': {
    'Purpose': 'Image Management'
  }
}
*/
param tags object = {}

@description('DO NOT MODIFY THIS VALUE! The timestamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddhhmm')

// Naming conventions
var cloud = toLower(environment().name)
// account for air-gapped cloud location prefixes
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location)-5) : location
#disable-next-line BCP329
var varRemoteLocation = !empty(remoteLocation) ? (startsWith(cloud, 'us') ? substring(remoteLocation, 5, length(remoteLocation)-5) : remoteLocation) : ''
var locations = startsWith(cloud, 'us') ? (loadJsonContent('../../.common/data/locations.json')).other : (loadJsonContent('../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')
var nameConv_Suffix_withoutResType = 'LOCATION'
var nameConvSuffix = nameConvResTypeAtEnd ? '${nameConv_Suffix_withoutResType}-RESOURCETYPE' : nameConv_Suffix_withoutResType
var identifier = empty(customIdentifier) ? 'image-management' : customIdentifier
var nameConv_ImageManagement_ResGroup = nameConvResTypeAtEnd ? 'avd-${identifier}-${nameConvSuffix}' : 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var nameConv_ImageManagement_Resources = nameConvResTypeAtEnd ? 'avd-${identifier}-${nameConvSuffix}' : 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
#disable-next-line BCP329
var resourceGroupName = replace(replace(nameConv_ImageManagement_ResGroup, 'LOCATION', locations[varLocation].abbreviation), 'RESOURCETYPE', resourceAbbreviations.resourceGroups)
#disable-next-line BCP329
var remoteResourceGroupName = !empty(remoteLocation) ? replace(replace(nameConv_ImageManagement_ResGroup, 'LOCATION', locations[varRemoteLocation].abbreviation), 'RESOURCETYPE', resourceAbbreviations.resourceGroups) : ''
var blobContainerName = replace(replace(toLower(artifactsContainerName), '_', '-'), ' ', '-')
var galleryName = replace(replace(replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.computeGalleries), 'LOCATION', locations[varLocation].abbreviation), '-', '_')
var remoteGalleryName = !empty(remoteLocation) ? replace(replace(replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.computeGalleries), 'LOCATION', locations[varRemoteLocation].abbreviation), '-', '_') : ''
var identityName = replace(replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities), 'LOCATION', locations[varLocation].abbreviation)
var vnetName = !empty(privateEndpointSubnetResourceId) ? split(privateEndpointSubnetResourceId, '/')[8] : ''
var privateEndpointNameConv = replace('${nameConvResTypeAtEnd ? 'RESOURCE-SUBRESOURCE-${vnetName}-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-${vnetName}'}', 'RESOURCETYPE', resourceAbbreviations.privateEndpoints)
var privateEndpointName = replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'), 'RESOURCE', storageName)
var customNetworkInterfaceName = nameConvResTypeAtEnd ? '${privateEndpointName}-${resourceAbbreviations.networkInterfaces}' : '${resourceAbbreviations.networkInterfaces}-${privateEndpointName}'
var storageName = take('${resourceAbbreviations.storageAccounts}imageassets${locations[varLocation].abbreviation}${uniqueString(subscription().subscriptionId, resourceGroupName)}', 24)
var storageKind = 'StorageV2'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags.?resourceGroups ?? {}
}

module resources 'resources.bicep' = {
  scope: az.resourceGroup(resourceGroupName)
  name: 'Image-Management-Resources-${timeStamp}'
  params: {
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId
    computeGalleryName: galleryName
    customNetworkInterfaceName: customNetworkInterfaceName
    storageAccountName: storageName
    blobContainerName: blobContainerName
    managedIdentityName: identityName
    privateEndpointName: privateEndpointName
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    storageAccessTier: storageAccessTier
    storageSASExpirationPeriod: storageSASExpirationPeriod
    storageKind: storageKind
    storageSkuName: storageSkuName
    storagePermittedIPs: storagePermittedIPs
    storageServiceEndpointSubnetResourceIds: storageServiceEndpointSubnetResourceIds
    storageAllowPublicNetworkAccess: storagePublicNetworkAccess
    storageAllowSharedKeyAccess: storageAllowSharedKeyAccess
    tags: tags != {} ? tags : null
  }
  dependsOn: [
    resourceGroup
  ]
}

resource remoteResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = if(!empty(remoteLocation)) {
  name: remoteResourceGroupName
  location: remoteLocation
  tags: tags.?resourceGroups ?? {}
}

module remoteImageGallery '../sharedModules/resources/compute/gallery/main.bicep' = if(!empty(remoteLocation)) {
  name: 'Remote-Image-Gallery-${timeStamp}'
  scope: az.resourceGroup(remoteResourceGroupName)
  params: {
    location: location
    name: remoteGalleryName
    tags: tags.?computeGalleries ?? {}
  }
  dependsOn: [
    remoteResourceGroup
  ]
}

output storageAccountResourceId string    = resources.outputs.storageAccountResourceId
output blobContainerName string           = resources.outputs.blobContainerName
output blobContainerUrl string = resources.outputs.blobcontainerUrl
output managedIdentityClientId string     = resources.outputs.managedIdentityClientId
output managedIdentityResourceId string   = resources.outputs.managedIdentityResourceId
output computeGalleryResourceId string   = resources.outputs.computeGalleryResourceId
output computeGalleryName string         = resources.outputs.computeGalleryName
#disable-next-line BCP318
output remoteComputeGalleryResourceId string = !empty(remoteLocation) ? remoteImageGallery.outputs.resourceId : ''

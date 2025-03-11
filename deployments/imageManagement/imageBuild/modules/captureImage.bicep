targetScope = 'subscription'

param computeGalleryResourceId string
param depPrefix string
param hyperVGeneration string
param imageBuildResourceGroupName string
param imageDefinitionSecurityType string
param imageName string
param imageVersionName string
param imageVersionDefaultReplicaCount int
param imageVersionDefaultStorageAccountType string
param imageVersionEndOfLifeDate string
param imageVersionExcludeFromLatest bool
param imageVersionReplicationRegions array
param location string
param tags object
param timeStamp string
param virtualMachineResourceId string




// Image Definitions with Security Type = 'TrustedLaunchSupported', 'ConfidentialVMSupported', or TrustedLaunchConfidentialVMSupported' do not
// support capture directly from a VM. Must create a legacy managed image first.

module managedImage '../../../sharedModules/resources/compute/image/main.bicep' = if(contains(imageDefinitionSecurityType, 'Supported')) {
  name: '${depPrefix}Image-${timeStamp}'
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    hyperVGeneration: hyperVGeneration
    location: location
    name: 'img-${last(split(virtualMachineResourceId, '/'))}'
    sourceVirtualMachineResourceId: virtualMachineResourceId
    tags: tags[?'Microsoft.Compute/images'] ?? {}
  }
}

module imageVersion '../../../sharedModules/resources/compute/gallery/image/version/main.bicep' = {
  name: '${depPrefix}ImageVersion-${timeStamp}'
  scope: resourceGroup(split(computeGalleryResourceId, '/')[2], split(computeGalleryResourceId, '/')[4])
  params: {
    location: location
    name: imageVersionName
    confidentialVMEncryptionType: imageDefinitionSecurityType == 'ConfidentialVM' ? 'EncryptedVMGuestStateOnlyWithPmk' : null
    galleryName: last(split(computeGalleryResourceId, '/'))
    imageName: imageName
    endOfLifeDate: imageVersionEndOfLifeDate
    excludeFromLatest: imageVersionExcludeFromLatest
    hostCaching: 'ReadWrite'
    replicaCount: imageVersionDefaultReplicaCount
    replicationMode: 'Full'
    storageAccountType: imageVersionDefaultStorageAccountType
    sourceId: contains(imageDefinitionSecurityType, 'Supported') ? managedImage.outputs.resourceId : null
    virtualMachineId: contains(imageDefinitionSecurityType, 'Supported') ? null : virtualMachineResourceId
    targetRegions: imageVersionReplicationRegions
    tags: tags[?'Microsoft.Compute/galleries/images/versions'] ?? {}
  }
}

output managedImageId string = contains(imageDefinitionSecurityType, 'Supported') ? managedImage.outputs.resourceId : ''
output imageVersionId string = imageVersion.outputs.resourceId

targetScope = 'subscription'

import { galleryImageVersionTargetRegionType } from '../../shared/modules/resourceModules/types/computeTypes.bicep'

param computeGalleryResourceId string
param hyperVGeneration string
param imageBuildResourceGroupName string
param imageDefinitionSecurityType string
param imageName string
param imageVersionName string
param imageVersionDefaultReplicaCount int
param imageVersionDefaultStorageAccountType string
param imageVersionEndOfLifeDate string
param imageVersionExcludeFromLatest bool
param imageVersionReplicationRegions galleryImageVersionTargetRegionType[]
param location string
param tags object
param virtualMachineResourceId string
param diskEncryptionSetId string = ''
param confidentialVMEncryptionType string = ''
param secureVMDiskEncryptionSetId string = ''

// Image Definitions with Security Type = 'TrustedLaunchSupported', 'ConfidentialVMSupported', or TrustedLaunchConfidentialVMSupported' do not
// support capture directly from a VM. Must create a legacy managed image first.

module managedImage '../../shared/modules/resourceModules/compute/images/deploy.bicep' = if(contains(imageDefinitionSecurityType, 'Supported')) {
  scope: resourceGroup(imageBuildResourceGroupName)
  params: {
    hyperVGeneration: hyperVGeneration
    location: location
    name: 'img-${last(split(virtualMachineResourceId, '/'))}'
    sourceVirtualMachineResourceId: virtualMachineResourceId
    tags: tags[?'Microsoft.Compute/images'] ?? {}
  }
}

module imageVersion '../../shared/modules/resourceModules/compute/galleries/images/versions/deploy.bicep' = {
  scope: resourceGroup(split(computeGalleryResourceId, '/')[2], split(computeGalleryResourceId, '/')[4])
  params: {
    location: location
    name: imageVersionName
    galleryName: last(split(computeGalleryResourceId, '/'))
    imageDefinitionName: imageName
    endOfLifeDate: imageVersionEndOfLifeDate
    excludeFromLatest: imageVersionExcludeFromLatest
    hostCaching: 'ReadWrite'
    replicaCount: imageVersionDefaultReplicaCount
    replicationMode: 'Full'
    storageAccountType: imageVersionDefaultStorageAccountType
    sourceId: contains(imageDefinitionSecurityType, 'Supported') ? managedImage!.outputs.resourceId : ''
    virtualMachineId: !contains(imageDefinitionSecurityType, 'Supported') ? virtualMachineResourceId : ''
    targetRegions: imageVersionReplicationRegions
    diskEncryptionSetId: diskEncryptionSetId
    confidentialVMEncryptionType: confidentialVMEncryptionType
    secureVMDiskEncryptionSetId: secureVMDiskEncryptionSetId
    tags: tags[?'Microsoft.Compute/galleries/images/versions'] ?? {}
  }
}

output managedImageId string = contains(imageDefinitionSecurityType, 'Supported') ? managedImage!.outputs.resourceId : ''
output imageVersionId string = imageVersion.outputs.resourceId

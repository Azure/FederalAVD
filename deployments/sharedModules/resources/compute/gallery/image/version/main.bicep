@sys.description('Required. Name of the image version.')
param name string

@sys.description('Optional. Location for all resources.')
param location string = resourceGroup().location

@sys.description('Conditional. The name of the parent Azure Shared Image Gallery Image Definition. Required if the template is used in a standalone deployment.')
@minLength(1)
param imageName string

@sys.description('Conditional. The name of the Azure Compute gallery that contains the Image Definition for which this version will be created.')
@minLength(1)
param galleryName string

@sys.description('Optional. The end of life date as a string.')
param endOfLifeDate string = ''

@sys.description('Optional. If set to true, Virtual Machines deployed from the latest version of the Image Definition will not use this Image Version.')
param excludeFromLatest bool = false

@sys.description('Optional. The number of replicas of the Image Version to be created per region. This property would take effect for a region when regionalReplicaCount is not specified. This property is updatable.')
param replicaCount int

@sys.description('Optional. Optional parameter which specifies the mode to be used for replication. This property is not updatable.')
@allowed([
  'Full'
  'Shallow'
])
param replicationMode string = 'Full'

@sys.description('Optional. Specifies the storage account type to be used to store the image. This property is not updatable.')
@allowed([
  'Premium_LRS'
  'Standard_LRS'
  'Standard_ZRS'
])
param storageAccountType string = 'Standard_LRS'

@sys.description('Optional. The target regions where the Image Version is going to be replicated to. If this object is not specified, then the deployment location will be used.')
param targetRegions array = []

@sys.description('Optional. A relative URI containing the resource ID of the disk encryption set.')
param diskEncryptionSetId string = ''

@sys.description('Optional. Confidential VM encryption types')
@allowed([
  ''
  'EncryptedVMGuestStateOnlyWithPmk'
  'EncryptedWithCmk'
  'EncryptedWithPmk'
])
param confidentialVMEncryptionType string = ''

@sys.description('Optional. Secure VM disk encryption set id.')
param secureVMDiskEncryptionSetId string = ''

@sys.description('Optional. Indicates whether or not removing this Gallery Image Version from replicated regions is allowed.')
param allowDeletionOfReplicatedLocations bool = true

@sys.description('Optional. The host caching of the disk.')
@allowed([
  'None'
  'ReadOnly'
  'ReadWrite'
])
param hostCaching string = 'None'

@sys.description('Optional. The id of the gallery artifact version source. Can specify a OS disk resource id or snapshot resource id.')
param osDiskImageSourceId string = ''

@sys.description('Optional. The uri of the gallery artifact version source. Currently used to specify vhd/blob source.')
param osDiskImageSourceUri string = ''

@sys.description('Optional. The id of the gallery artifact version source. Can specify a managed disk resource id, snapshot resource id, or storage account resource.')
param sourceId string = ''

@sys.description('Optional. Tags for all resources.')
param tags object = {}

@sys.description('Optional. The virtual machine id of the source image.')
param virtualMachineId string = ''

var storageProfile = !empty(sourceId) || !empty(virtualMachineId)
  ? {
      source: {
        id: !empty(sourceId) ? sourceId : null
        virtualMachineId: !empty(virtualMachineId) ? virtualMachineId : null
      }
    }
  : {
      osDiskImage: {
        hostCaching: hostCaching
        source: {
          id: !empty(osDiskImageSourceId) ? osDiskImageSourceId : null
          uri: !empty(osDiskImageSourceUri) ? osDiskImageSourceUri : null
        }
      }
    }

var targetRegionDefault = [
  {
    encryption: !empty(diskEncryptionSetId)
      ? {
          osDiskImage: {
            diskEncryptionSetId: diskEncryptionSetId
            securityProfile: {
              confidentialVMEncryptionType: !empty(confidentialVMEncryptionType) ? confidentialVMEncryptionType : null
              secureVMDiskEncryptionSetId: !empty(secureVMDiskEncryptionSetId) ? secureVMDiskEncryptionSetId : null
            }
          }
        }
      : null
    name: location
    storageAccountType: storageAccountType
  }
]
// determine if targetRegions contains the deployment location with the next two variables
var regionMatchArray = [for region in targetRegions: region.name == location ? true : false]
var targetRegionsContainsLocation = contains(regionMatchArray, true) ? true : false
// cannot simply use a union function on an array of objects because there could be duplicates which will cause failures.
var targetRegionsVar = !empty(targetRegions)
  ? (targetRegionsContainsLocation ? targetRegions : union(targetRegions, targetRegionDefault))
  : targetRegionDefault

resource gallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: galleryName
  resource image 'images@2022-03-03' existing = {
    name: imageName
  }
}

resource version 'Microsoft.Compute/galleries/images/versions@2024-03-03' = {
  location: location
  name: name
  parent: gallery::image
  properties: {
    publishingProfile: {
      endOfLifeDate: !empty(endOfLifeDate) ? endOfLifeDate : null
      excludeFromLatest: excludeFromLatest
      replicaCount: replicaCount
      replicationMode: replicationMode
      storageAccountType: storageAccountType
      targetRegions: targetRegionsVar
    }
    safetyProfile: {
      allowDeletionOfReplicatedLocations: allowDeletionOfReplicatedLocations
    }
    storageProfile: storageProfile
  }
  tags: tags
}

@sys.description('The resource group the image was deployed into.')
output resourceGroupName string = resourceGroup().name

@sys.description('The resource ID of the image version.')
output resourceId string = version.id

@sys.description('The name of the image version.')
output name string = version.name

@sys.description('The location the resource was deployed into.')
output location string = version.location

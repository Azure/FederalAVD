param galleryName string
param imageDefinitionName string
param name string
param location string = resourceGroup().location
param tags object = {}

@description('Resource ID of the source (managed image or VM).')
param sourceId string = ''

@description('Resource ID of the source virtual machine (alternative to sourceId).')
param virtualMachineId string = ''

@description('End of life date (ISO 8601). Empty string = no EOL.')
param endOfLifeDate string = ''

@description('Exclude this version from latest.')
param excludeFromLatest bool = false

@description('Default replica count per region.')
param replicaCount int = 1

@description('Default storage account type.')
@allowed(['Standard_LRS', 'Standard_ZRS', 'Premium_LRS'])
param storageAccountType string = 'Standard_LRS'

@description('Replication mode.')
@allowed(['Full', 'Shallow'])
param replicationMode string = 'Full'

@description('Host caching setting.')
@allowed(['None', 'ReadOnly', 'ReadWrite'])
param hostCaching string = 'ReadOnly'

@description('Optional. Target regions for replication. Overrides replicaCount/storageAccountType if provided.')
param targetRegions array = []

var resolvedTargetRegions = !empty(targetRegions)
  ? targetRegions
  : [
      {
        name: location
        regionalReplicaCount: replicaCount
        storageAccountType: storageAccountType
        excludeFromLatest: excludeFromLatest
      }
    ]

resource gallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: galleryName
  resource imageDef 'images@2022-03-03' existing = {
    name: imageDefinitionName
  }
}

resource imageVersion 'Microsoft.Compute/galleries/images/versions@2024-03-03' = {
  parent: gallery::imageDef
  name: name
  location: location
  tags: tags
  properties: {    
    storageProfile: {
      osDiskImage: {
        hostCaching: hostCaching
        source: !empty(sourceId)
          ? { id: sourceId }
          : !empty(virtualMachineId) ? { id: virtualMachineId } : null
      }
    }
    publishingProfile: {
      targetRegions: resolvedTargetRegions
      endOfLifeDate: !empty(endOfLifeDate) ? endOfLifeDate : null
      excludeFromLatest: excludeFromLatest
      replicaCount: replicaCount
      replicationMode: replicationMode
      storageAccountType: storageAccountType
    }
  }
}

output resourceId string = imageVersion.id
output name string = imageVersion.name

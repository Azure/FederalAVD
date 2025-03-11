param galleryName string
param imageDefinitionName string
param versionName string
param defaultReplicaCount int
param excludedFromLatest bool
param regionReplications array = [
  {
    name: 'eastus2'
    regionalReplicaCount: 1
    storageAccountType: 'Standard_ZRS'
  }
]
param location string
param replicationMode string = 'Full'
param sourceImageId string

resource galleryName_imageDefinitionName_version 'Microsoft.Compute/galleries/images/versions@2023-07-03' = {
  name: '${galleryName}/${imageDefinitionName}/${versionName}'
  location: location
  tags: {}
  properties: {
    publishingProfile: {
      replicaCount: defaultReplicaCount
      targetRegions: regionReplications
      excludeFromLatest: excludedFromLatest
      storageAccountType: 'Standard_ZRS'
      replicationMode: replicationMode
    }
    storageProfile: {
      source: {
        id: sourceImageId
      }
    }
  }
  dependsOn: []
}

param diskId string = '/subscriptions/67edfd17-f0d1-466a-aacb-ca9daeabb9b8/resourceGroups/RG-VMIMAGETESTS/providers/Microsoft.Compute/disks/TrustedLaunch_OsDisk_1_09b8a9bc852e4e52b1f0bf784759a958'
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
param replicationMode string

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
      osDiskImage: {
        hostCaching: 'None'
        source: {
          id: diskId
        }
      }
    }
  }
  dependsOn: []
}

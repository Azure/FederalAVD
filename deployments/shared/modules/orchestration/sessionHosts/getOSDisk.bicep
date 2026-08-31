param diskAccessId string
param diskName string
param location string

resource getDisk 'Microsoft.Compute/disks@2023-10-02' existing = {
  name: diskName
}

module updateDisk 'updateOSDisk.bicep' = {
  params: {
    diskName: diskName
    creationData: getDisk.properties.creationData
    diskAccessId: diskAccessId
    location: location
  }
}

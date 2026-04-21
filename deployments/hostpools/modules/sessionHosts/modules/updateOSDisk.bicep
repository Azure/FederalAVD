param diskName string
param diskAccessId string
param location string

resource existingDisk 'Microsoft.Compute/disks@2023-10-02' existing = {
  name: diskName
}

resource diskUpdate 'Microsoft.Compute/disks@2023-10-02' = {
  name: diskName
  location: location
  properties: {
    diskAccessId: empty(diskAccessId) ? null : diskAccessId
    creationData: {
      createOption: existingDisk.properties.creationData.createOption
    }
    networkAccessPolicy: empty(diskAccessId) ? 'DenyAll' : 'AllowPrivate'
    publicNetworkAccess: 'Disabled'
  }
}

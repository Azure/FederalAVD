param creationData object
param diskName string
param diskAccessId string
param location string

resource diskUpdate 'Microsoft.Compute/disks@2023-10-02' = {
  name: diskName
  location: location
  properties: {
    diskAccessId: empty(diskAccessId) ? null : diskAccessId
    creationData: creationData
    networkAccessPolicy: empty(diskAccessId) ? 'DenyAll' : 'AllowPrivate'
    publicNetworkAccess: 'Disabled'
  }
}

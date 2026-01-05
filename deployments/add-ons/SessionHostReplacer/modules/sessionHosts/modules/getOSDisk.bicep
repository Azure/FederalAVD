param diskAccessId string
param diskName string
param location string
param deploymentSuffix string
param vmName string

resource getDisk 'Microsoft.Compute/disks@2023-10-02' existing = {
  name: diskName
}

module updateDisk 'updateOSDisk.bicep' = {
  name: 'Update-OSDisk-${vmName}-Stage2-${deploymentSuffix}'
  params: {
    diskName: diskName
    creationData: getDisk.properties.creationData
    diskAccessId: diskAccessId
    location: location
  }
}


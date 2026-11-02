metadata name = 'OS disk network update orchestration'
metadata description = 'Reads creation data from an existing managed OS disk and forwards it to the disk network-access update in the deployment resource group.'

@description('Required. Resource ID of an existing disk access resource; empty selects DenyAll instead of AllowPrivate network access.')
param diskAccessId string
@description('Required. Name of the existing managed OS disk in the deployment resource group.')
param diskName string
@description('Required. Azure region for the resources deployed by this module.')
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

metadata name = 'OS disk network access update'
metadata description = 'Updates a managed disk using preserved creation data, disables public network access, and selects private-only or deny-all network access according to the supplied disk access resource ID.'

@description('Required. Existing disk creationData object read from the managed disk and preserved in the update request.')
param creationData object
@description('Required. Name of the existing managed OS disk in the deployment resource group.')
param diskName string
@description('Required. Resource ID of an existing disk access resource; empty selects DenyAll instead of AllowPrivate network access.')
param diskAccessId string
@description('Required. Azure region for the resources deployed by this module.')
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

targetScope = 'subscription'

@description('Required. Name of the resource group where the DiskAccess resource and its private endpoint will be deployed.')
param resourceGroupHosts string

@description('Required. Name for the DiskAccess resource.')
param diskAccessName string

@description('Required. Azure region for the DiskAccess resource.')
param location string

@description('Required. Resource ID of the AVD host pool (used as the cm-resource-parent tag).')
param hostPoolResourceId string

@description('Required. Short unique deployment suffix.')
param deploymentSuffix string

@description('Required. Resource tags object.')
param tags object = {}

@description('Required. Whether to deploy a private endpoint for the DiskAccess resource.')
param deployPrivateEndpoint bool

@description('Optional. Resource ID of the subnet for the DiskAccess private endpoint.')
param privateEndpointSubnetResourceId string = ''

@description('Required. Name convention string for private endpoint resources.')
param privateEndpointNameConv string

@description('Required. Name convention string for private endpoint NICs.')
param privateEndpointNICNameConv string

@description('Optional. Resource ID of the Azure Blob private DNS zone for the disk access private endpoint.')
param azureBlobPrivateDnsZoneResourceId string = ''

module diskAccessResource '../../../../../.common/bicepModules/compute/diskAccesses/deploy.bicep' = {
  scope: resourceGroup(resourceGroupHosts)
  name: 'DiskAccess-${deploymentSuffix}'
  params: {
    name: diskAccessName
    location: location
    tags: union({'cm-resource-parent': hostPoolResourceId}, tags[?'Microsoft.Compute/diskAccesses'] ?? {})
  }
}

module diskAccessPrivateEndpoint '../../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deployPrivateEndpoint && !empty(privateEndpointSubnetResourceId)) {
  scope: resourceGroup(resourceGroupHosts)
  name: 'PE-DiskAccess-${deploymentSuffix}'
  params: {
    name: replace(replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'disks'), 'RESOURCE', diskAccessName), 'VNETID', split(privateEndpointSubnetResourceId, '/')[8])
    customNetworkInterfaceName: replace(replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'disks'), 'RESOURCE', diskAccessName), 'VNETID', split(privateEndpointSubnetResourceId, '/')[8])
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: diskAccessResource.outputs.resourceId
    groupId: 'disks'
    privateDNSZoneIds: !empty(azureBlobPrivateDnsZoneResourceId) ? [azureBlobPrivateDnsZoneResourceId] : []
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

output diskAccessId string = diskAccessResource.outputs.resourceId

targetScope = 'subscription'

param resourceGroupHosts string
param diskAccessName string
param location string
param hostPoolResourceId string
param deploymentSuffix string
param tags object = {}
param deployPrivateEndpoint bool
param privateEndpointSubnetResourceId string = ''
param privateEndpointNameConv string
param privateEndpointNICNameConv string
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

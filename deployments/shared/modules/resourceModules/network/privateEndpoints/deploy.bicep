metadata name = 'Private endpoint'
metadata description = 'Deploys a private endpoint in an existing subnet for one target subresource, with an optional NIC name and DNS zone group referencing existing private DNS zones.'

@description('Required. Name of the private endpoint to deploy.')
param name string
@description('Optional. Azure region for the private endpoint; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the private endpoint.')
param tags object = {}

@description('Resource ID of the subnet to deploy the private endpoint into.')
param subnetResourceId string

@description('Resource ID of the resource to create the private endpoint for.')
param privateLinkServiceId string

@description('Group ID (sub-resource) of the private link service.')
param groupId string

@description('Optional. Custom name for the network interface created for this endpoint.')
param customNetworkInterfaceName string = ''

@description('Optional. Private DNS zone group: resource IDs of private DNS zones to register this endpoint in.')
param privateDNSZoneIds array = []

var privateDnsZoneConfigs = [for privateDNSId in privateDNSZoneIds: {
  name: replace(last(split(privateDNSId, '/'))!, '.', '-')
  properties: {
    privateDnsZoneId: privateDNSId
  }
}]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetResourceId
    }
    customNetworkInterfaceName: !empty(customNetworkInterfaceName) ? customNetworkInterfaceName : null
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: [groupId]
        }
      }
    ]    
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = if (!empty(privateDNSZoneIds)) {
  name: 'default'
  parent: privateEndpoint
  properties: {
    privateDnsZoneConfigs: privateDnsZoneConfigs
  }
}

@description('Resource ID of the private endpoint.')
output resourceId string = privateEndpoint.id
@description('Azure resource name of the private endpoint.')
output name string = privateEndpoint.name

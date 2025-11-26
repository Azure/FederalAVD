metadata name = 'Private Endpoints'

@description('Required. Name of the private endpoint resource to create.')
param name string

@description('Required. Resource ID of the subnet where the endpoint needs to be created.')
param subnetResourceId string

@description('Required. Resource ID of the resource that needs to be connected to the network.')
param serviceResourceId string

@description('Optional. Application security groups in which the private endpoint IP configuration is included.')
param applicationSecurityGroups array = []

@description('Optional. The custom name of the network interface attached to the private endpoint.')
param customNetworkInterfaceName string = ''

@description('Optional. A list of IP configurations of the private endpoint. This will be used to map to the First Party Service endpoints.')
param ipConfigurations array = []

@description('Required. Subtype(s) of the connection to be created. The allowed values depend on the type serviceResourceId refers to.')
param groupIds array

@description('Optional. The private DNS zone group configuration used to associate the private endpoint with one or multiple private DNS zones. A DNS zone group can support up to 5 DNS zones.')
param privateDnsZoneGroup object = {}

@description('Optional. Location for all Resources.')
param location string = resourceGroup().location

@description('Optional. Tags to be applied on all resources/resource groups in this deployment.')
param tags object = {}

@description('Optional. Custom DNS configurations.')
param customDnsConfigs array = []

@description('Optional. Manual PrivateLink Service Connections.')
param manualPrivateLinkServiceConnections array = []

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    applicationSecurityGroups: applicationSecurityGroups
    customDnsConfigs: customDnsConfigs
    customNetworkInterfaceName: customNetworkInterfaceName
    ipConfigurations: ipConfigurations
    manualPrivateLinkServiceConnections: manualPrivateLinkServiceConnections
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: serviceResourceId
          groupIds: groupIds
        }
      }
    ]
    subnet: {
      id: subnetResourceId
    }
  }
}

module privateEndpoint_privateDnsZoneGroup 'private-dns-zone-group/main.bicep' = if (!empty(privateDnsZoneGroup)) {
  name: 'PE-PrivateDnsZoneGroup-${uniqueString(deployment().name)}'
  params: {
    privateDNSResourceIds: privateDnsZoneGroup.privateDNSResourceIds
    privateEndpointName: privateEndpoint.name
  }
}

@description('The resource group the private endpoint was deployed into.')
output resourceGroupName string = resourceGroup().name

@description('The resource ID of the private endpoint.')
output resourceId string = privateEndpoint.id

@description('The name of the private endpoint.')
output name string = privateEndpoint.name

@description('The location the resource was deployed into.')
output location string = privateEndpoint.location

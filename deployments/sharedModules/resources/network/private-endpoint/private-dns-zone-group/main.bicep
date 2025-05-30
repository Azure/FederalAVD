@description('Conditional. The name of the parent private endpoint. Required if the template is used in a standalone deployment.')
param privateEndpointName string

@description('Required. Array of private DNS zone resource IDs. A DNS zone group can support up to 5 DNS zones.')
@minLength(1)
@maxLength(5)
param privateDNSResourceIds array

@description('Optional. The name of the private DNS zone group.')
param name string = 'default'

var privateDnsZoneConfigs = [for privateDNSResourceId in privateDNSResourceIds: {
  name: last(split(privateDNSResourceId, '/'))!
  properties: {
    privateDnsZoneId: privateDNSResourceId
  }
}]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' existing = {
  name: privateEndpointName
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: name
  parent: privateEndpoint
  properties: {
    privateDnsZoneConfigs: privateDnsZoneConfigs
  }
}

@description('The name of the private endpoint DNS zone group.')
output name string = privateDnsZoneGroup.name

@description('The resource ID of the private endpoint DNS zone group.')
output resourceId string = privateDnsZoneGroup.id

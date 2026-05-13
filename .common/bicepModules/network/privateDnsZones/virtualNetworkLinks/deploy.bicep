param privateDnsZoneName string
param name string
param tags object = {}

@description('Resource ID of the virtual network to link.')
param vnetResourceId string

@description('Enable auto-registration of VM DNS records in this zone.')
param registrationEnabled bool = false

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: privateDnsZoneName
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: name
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnetResourceId }
    registrationEnabled: registrationEnabled
  }
}

output resourceId string = vnetLink.id
output name string = vnetLink.name

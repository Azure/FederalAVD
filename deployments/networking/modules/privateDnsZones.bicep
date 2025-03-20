param privateDnsZoneNames array
param tags object = {}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for name in privateDnsZoneNames: {
  name: name
  location: 'global'
  tags: tags
}]

output resourceIds array = [for (name, i) in privateDnsZoneNames: privateDnsZones[i].id]

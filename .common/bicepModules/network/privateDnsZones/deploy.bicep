// Private DNS zones are global resources — no location parameter.
param name string
param tags object = {}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: name
  location: 'global'
  tags: tags
}

output resourceId string = privateDnsZone.id
output name string = privateDnsZone.name

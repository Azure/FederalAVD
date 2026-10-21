metadata name = 'Private DNS zone'
metadata description = 'Deploys a global private DNS zone in the deployment resource group; virtual network links and private endpoint zone groups are managed separately.'

// Private DNS zones are global resources — no location parameter.
@description('Required. Name of the private DNS zone to deploy.')
param name string
@description('Optional. Tags applied to the private DNS zone.')
param tags object = {}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: name
  location: 'global'
  tags: tags
}

@description('Resource ID of the private DNS zone.')
output resourceId string = privateDnsZone.id
@description('Azure resource name of the private DNS zone.')
output name string = privateDnsZone.name

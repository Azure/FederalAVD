metadata name = 'Private DNS virtual network link'
metadata description = 'Links an existing virtual network to an existing private DNS zone in the deployment resource group, optionally enabling VM record registration.'

@description('Required. Name of the existing parent private DNS zone in the deployment resource group.')
param privateDnsZoneName string
@description('Required. Name of the private DNS virtual network link to deploy.')
param name string
@description('Optional. Tags applied to the private DNS virtual network link.')
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

@description('Resource ID of the private DNS virtual network link.')
output resourceId string = vnetLink.id
@description('Azure resource name of the private DNS virtual network link.')
output name string = vnetLink.name

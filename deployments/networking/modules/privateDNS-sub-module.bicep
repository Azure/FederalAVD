targetScope = 'subscription'

param createPrivateDNSZones bool
param deployPrivateDNSZonesResourceGroup bool
param existingPrivateDnsZoneIds array
param location string
param privateDNSZonesResourceGroupName string
param privateDnsZonesToCreate array
param privateDnsZonesVnetId string
param tags object
param timeStamp string


resource privateDNSZonesResourceGroup 'Microsoft.Resources/resourceGroups@2024-07-01' = if (deployPrivateDNSZonesResourceGroup) {
  name: privateDNSZonesResourceGroupName
  location: location
  tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
}

module privateDNSZones 'privateDnsZones.bicep' = if(createPrivateDNSZones) {
  name: 'Private-DNS-Zones-${timeStamp}'
  scope: resourceGroup(privateDNSZonesResourceGroupName)
  params: {
    privateDnsZoneNames: privateDnsZonesToCreate
    tags: tags[?'Microsoft.Network/privateDnsZones'] ?? {}
  }
  dependsOn: [
    privateDNSZonesResourceGroup
  ]
}

module privateDNSZonesVnetLinks 'privateDnsZonesVnetLinks.bicep' = if(!empty(privateDnsZonesVnetId)) {
  name: 'Private-DNS-Zones-Vnet-Links-${timeStamp}'
  params: {
    privateDnsZoneResourceIds: createPrivateDNSZones ? union(privateDNSZones.outputs.resourceIds, existingPrivateDnsZoneIds) : existingPrivateDnsZoneIds
    vnetId: privateDnsZonesVnetId
    timeStamp: timeStamp
  }
}

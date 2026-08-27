targetScope = 'subscription'

param createPrivateDNSZones bool
param deployPrivateDNSZonesResourceGroup bool
param existingPrivateDnsZoneIds array
param location string
param privateDNSZonesResourceGroupName string
param privateDnsZonesToCreate array
param privateDnsZonesVnetId string
param tags object


resource privateDNSZonesResourceGroup 'Microsoft.Resources/resourceGroups@2024-07-01' = if (deployPrivateDNSZonesResourceGroup) {
  name: privateDNSZonesResourceGroupName
  location: location
  tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
}

module privateDNSZones 'privateDnsZones.bicep' = if(createPrivateDNSZones) {
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
  params: {
    privateDnsZoneResourceIds: createPrivateDNSZones ? union(privateDNSZones!.outputs.resourceIds, existingPrivateDnsZoneIds) : existingPrivateDnsZoneIds
    vnetId: privateDnsZonesVnetId
  }
}

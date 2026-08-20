param name string
param location string = resourceGroup().location
param tags object = {}

@allowed(['Basic', 'Standard'])
param sku string = 'Standard'

@allowed(['Static', 'Dynamic'])
param allocationMethod string = 'Static'

@description('Optional. Availability zones for zone-redundant deployment.')
param zones array = []

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    tier: 'Regional'
  }
  zones: !empty(zones) ? zones : null
  properties: {
    publicIPAllocationMethod: allocationMethod
  }
}

output resourceId string = publicIPAddress.id
output name string = publicIPAddress.name

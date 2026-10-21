metadata name = 'Public IP address'
metadata description = 'Deploys a regional public IP address with caller-selected SKU, allocation method and optional availability zones; consumers are attached separately.'

@description('Required. Name of the public IP address to deploy.')
param name string
@description('Optional. Azure region for the public IP address; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the public IP address.')
param tags object = {}

@allowed(['Basic', 'Standard'])
@description('Optional. Public IP SKU; must be compatible with allocation method and availability zones.')
param sku string = 'Standard'

@allowed(['Static', 'Dynamic'])
@description('Optional. Public IP allocation mode; must be compatible with the selected SKU.')
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

@description('Resource ID of the public IP address.')
output resourceId string = publicIPAddress.id
@description('Azure resource name of the public IP address.')
output name string = publicIPAddress.name

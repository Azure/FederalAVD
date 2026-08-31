param name string
param location string = resourceGroup().location
param tags object = {}

@description('Number of fault domains. Default is 2.')
param platformFaultDomainCount int = 2

@description('Number of update domains. Default is 5.')
param platformUpdateDomainCount int = 5

@description('SKU name. Use Aligned for managed disks.')
@allowed(['Aligned', 'Classic'])
param skuName string = 'Aligned'

resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-09-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    platformFaultDomainCount: platformFaultDomainCount
    platformUpdateDomainCount: platformUpdateDomainCount
  }
}

output resourceId string = availabilitySet.id
output name string = availabilitySet.name

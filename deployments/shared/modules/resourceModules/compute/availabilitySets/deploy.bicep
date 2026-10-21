metadata name = 'Availability set'
metadata description = 'Deploys an availability set with caller-selected fault and update domains; virtual machines are associated separately.'

@description('Required. Name of the availability set to deploy.')
param name string
@description('Optional. Azure region for the availability set; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the availability set.')
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

@description('Resource ID of the availability set.')
output resourceId string = availabilitySet.id
@description('Azure resource name of the availability set.')
output name string = availabilitySet.name

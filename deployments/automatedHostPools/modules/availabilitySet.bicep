targetScope = 'subscription'

@description('Required. Resource group that contains the automated session hosts.')
param resourceGroupName string

@description('Required. Availability Set naming convention. The trailing -## token is removed.')
param nameConvention string

@description('Required. Whether to deploy the managed Availability Set.')
param deploy bool

@description('Required. Azure region for the Availability Set and session hosts.')
param location string

@description('Optional. Tags applied to the Availability Set.')
param tags object = {}

module availabilitySet '../../shared/modules/resourceModules/compute/availabilitySets/deploy.bicep' = if (deploy) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: replace(nameConvention, '-##', '')
    location: location
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
    skuName: 'Aligned'
    tags: tags
  }
}

output resourceId string = deploy ? availabilitySet!.outputs.resourceId : ''

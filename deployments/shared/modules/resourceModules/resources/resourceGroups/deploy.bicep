metadata name = 'Resource group'
metadata description = 'Deploys a resource group at subscription scope with caller-supplied name, region and optional tags; resources within the group are managed separately.'

targetScope = 'subscription'

@description('Required. Name of the resource group to deploy.')
param name string
@description('Required. Azure region for the resource group; must match the parent resource where required.')
param location string
@description('Optional. Tags applied to the resource group.')
param tags object = {}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: name
  location: location
  tags: tags
}

@description('Resource ID of the resource group.')
output resourceId string = resourceGroup.id
@description('Azure resource name of the resource group.')
output name string = resourceGroup.name

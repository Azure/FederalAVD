metadata name = 'Disk access resource'
metadata description = 'Deploys a regional disk access resource; private endpoints and managed disk associations are configured separately.'

@description('Required. Name of the disk access resource to deploy.')
param name string
@description('Optional. Azure region for the disk access resource; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the disk access resource.')
param tags object = {}

resource diskAccess 'Microsoft.Compute/diskAccesses@2023-04-02' = {
  name: name
  location: location
  tags: tags
}

@description('Resource ID of the disk access resource.')
output resourceId string = diskAccess.id
@description('Azure resource name of the disk access resource.')
output name string = diskAccess.name

targetScope = 'subscription'

param name string
param location string
param tags object = {}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: name
  location: location
  tags: tags
}

output resourceId string = resourceGroup.id
output name string = resourceGroup.name

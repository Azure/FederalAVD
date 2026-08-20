param name string
param location string = resourceGroup().location
param tags object = {}

resource diskAccess 'Microsoft.Compute/diskAccesses@2023-04-02' = {
  name: name
  location: location
  tags: tags
}

output resourceId string = diskAccess.id
output name string = diskAccess.name

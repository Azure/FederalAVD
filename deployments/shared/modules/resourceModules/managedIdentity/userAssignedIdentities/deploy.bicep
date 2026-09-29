param existing bool = false
param name string
param location string = resourceGroup().location
param tags object = {}

resource userAssignedIdentity_existing 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (existing) {
  name: name
}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (!existing) {
  name: name
  location: location
  tags: tags
}

output resourceId string = existing ? userAssignedIdentity_existing.id : userAssignedIdentity.id
output name string = existing ? userAssignedIdentity_existing.name : userAssignedIdentity.name
output clientId string = existing ? userAssignedIdentity_existing!.properties.clientId : userAssignedIdentity.properties.clientId
output principalId string = existing ? userAssignedIdentity_existing!.properties.principalId : userAssignedIdentity.properties.principalId

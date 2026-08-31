@sys.description('Required. Name of the Azure Compute Gallery.')
@minLength(1)
param name string

@sys.description('Optional. Location for all resources.')
param location string = resourceGroup().location

@sys.description('Optional. Tags to apply to the gallery.')
param tags object = {}

@sys.description('Optional. Description of the Azure Compute Gallery.')
param description string = ''

@sys.description('Optional. User-assigned managed identity resource IDs attached to the Azure Compute Gallery.')
param userAssignedIdentityResourceIds string[] = []

var userAssignedIdentities = reduce(
  userAssignedIdentityResourceIds,
  {},
  (current, resourceId) => union(current, { '${resourceId}': {} })
)

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: name
  location: location
  tags: tags
  identity: !empty(userAssignedIdentityResourceIds)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: userAssignedIdentities
      }
    : null
  properties: {
    description: description
  }
}

output resourceId string = gallery.id
output name string = gallery.name

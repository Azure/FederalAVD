param galleryName string
param principalId string
param principalType string
param roleDefinitionId string

resource gallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: galleryName
}

// =============== //
// Role Assignment //
// =============== //

resource galleryRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(gallery.id, principalId, roleDefinitionId)
  scope: gallery
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalType: principalType
  }
}

output roleAssignmentId string = galleryRoleAssignment.id

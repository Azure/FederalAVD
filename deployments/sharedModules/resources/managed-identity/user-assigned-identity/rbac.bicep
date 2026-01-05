param identityName string
param principalId string
param principalType string
param roleDefinitionId string

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: identityName
}

// =============== //
// Role Assignment //
// =============== //

resource uaiRBAC 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(uai.id, principalId, roleDefinitionId)
  scope: uai
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalType: principalType
  }
}

output roleAssignmentId string = uaiRBAC.id

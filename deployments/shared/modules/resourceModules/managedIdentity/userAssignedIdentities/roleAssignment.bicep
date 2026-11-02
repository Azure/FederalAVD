metadata name = 'Managed identity resource role assignments'
metadata description = 'Applies role assignments scoped to an existing user-assigned identity resource; these authorize principals over the identity rather than granting the identity access to other resources.'

import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Required. Name of the existing user-assigned identity in the deployment resource group.')
param identityName string

@description('Role assignments to apply to this user-assigned identity.')
param assignments roleAssignmentType[]

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

var formattedAssignments = [for assignment in assignments: union(assignment, {
  roleDefinitionId: contains(assignment.roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
    ? assignment.roleDefinitionId
    : '/providers/Microsoft.Authorization/roleDefinitions/${assignment.roleDefinitionId}'
})]

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in formattedAssignments: {
    scope: identity
    name: guid(identity.id, assignment.principalId, assignment.roleDefinitionId)
    properties: {
      roleDefinitionId: assignment.roleDefinitionId
      principalId: assignment.principalId
      principalType: assignment.?principalType ?? 'ServicePrincipal'
      description: assignment.?description
    }
  }
]

@description('Array of role assignment resource IDs in the same order as the assignments input.')
output resourceIds array = [for (assignment, i) in formattedAssignments: roleAssignment[i].id]

metadata name = 'Disk encryption set role assignments'
metadata description = 'Applies deterministic role assignments at an existing disk encryption set in the deployment resource group; does not grant access to its encryption key.'

import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Name of the existing disk encryption set.')
param diskEncryptionSetName string

@description('Role assignments to apply to this disk encryption set.')
param assignments roleAssignmentType[]

resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-04-02' existing = {
  name: diskEncryptionSetName
}

var formattedAssignments = [for assignment in assignments: union(assignment, {
  roleDefinitionId: contains(assignment.roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
    ? assignment.roleDefinitionId
    : '/providers/Microsoft.Authorization/roleDefinitions/${assignment.roleDefinitionId}'
})]

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in formattedAssignments: {
    scope: diskEncryptionSet
    name: guid(diskEncryptionSet.id, assignment.principalId, assignment.roleDefinitionId)
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

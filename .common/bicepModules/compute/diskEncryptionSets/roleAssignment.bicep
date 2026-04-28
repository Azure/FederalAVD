import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Name of the existing disk encryption set.')
param diskEncryptionSetName string

@description('Role assignments to apply to this disk encryption set.')
param assignments roleAssignmentType[]

resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-04-02' existing = {
  name: diskEncryptionSetName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in assignments: {
    scope: diskEncryptionSet
    name: guid(diskEncryptionSet.id, assignment.principalId, assignment.roleDefinitionId)
    properties: {
      roleDefinitionId: contains(assignment.roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
        ? assignment.roleDefinitionId
        : '/providers/Microsoft.Authorization/roleDefinitions/${assignment.roleDefinitionId}'
      principalId: assignment.principalId
      principalType: assignment.?principalType ?? 'ServicePrincipal'
      description: assignment.?description
    }
  }
]

output resourceIds array = [for (assignment, i) in assignments: roleAssignment[i].id]

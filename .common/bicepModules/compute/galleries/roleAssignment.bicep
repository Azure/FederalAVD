import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Name of the existing compute gallery.')
param galleryName string

@description('Role assignments to apply to this gallery.')
param assignments roleAssignmentType[]

resource gallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: galleryName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in assignments: {
    scope: gallery
    name: guid(gallery.id, assignment.principalId, assignment.roleDefinitionId)
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

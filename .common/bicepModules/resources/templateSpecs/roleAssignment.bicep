import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

param templateSpecName string

@description('Role assignments to apply to this template spec.')
param assignments roleAssignmentType[]

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' existing = {
  name: templateSpecName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in assignments: {
    scope: templateSpec
    name: guid(templateSpec.id, assignment.principalId, assignment.roleDefinitionId)
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

import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Name of the existing application group.')
param applicationGroupName string

@description('Role assignments to apply to this application group.')
param assignments roleAssignmentType[]

resource applicationGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' existing = {
  name: applicationGroupName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in assignments: {
    scope: applicationGroup
    name: guid(applicationGroup.id, assignment.principalId, assignment.roleDefinitionId)
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

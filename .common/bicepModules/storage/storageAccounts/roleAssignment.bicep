import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

param storageAccountName string

@description('Role assignments to apply to this storage account.')
param assignments roleAssignmentType[]

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in assignments: {
    scope: storageAccount
    name: guid(storageAccount.id, assignment.principalId, assignment.roleDefinitionId)
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

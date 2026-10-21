metadata name = 'Storage account role assignments'
metadata description = 'Applies deterministic role assignments at an existing storage account in the deployment resource group.'

import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string

@description('Role assignments to apply to this storage account.')
param assignments roleAssignmentType[]

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

var formattedAssignments = [for assignment in assignments: union(assignment, {
  roleDefinitionId: contains(assignment.roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
    ? assignment.roleDefinitionId
    : '/providers/Microsoft.Authorization/roleDefinitions/${assignment.roleDefinitionId}'
})]

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in formattedAssignments: {
    scope: storageAccount
    name: guid(storageAccount.id, assignment.principalId, assignment.roleDefinitionId)
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

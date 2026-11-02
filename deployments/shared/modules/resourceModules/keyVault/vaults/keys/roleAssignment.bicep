metadata name = 'Key Vault key role assignments'
metadata description = 'Applies deterministic role assignments at an existing key within an existing Key Vault in the deployment resource group.'

import { roleAssignmentType } from '../../../types/roleAssignmentTypes.bicep'

@description('Required. Name of the existing parent Key Vault in the deployment resource group.')
param keyVaultName string
@description('Required. Name of the existing key within the selected Key Vault.')
param keyName string

@description('Role assignments to apply to this key vault key.')
param assignments roleAssignmentType[]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName

  resource key 'keys' existing = {
    name: keyName
  }
}

var formattedAssignments = [for assignment in assignments: union(assignment, {
  roleDefinitionId: contains(assignment.roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
    ? assignment.roleDefinitionId
    : '/providers/Microsoft.Authorization/roleDefinitions/${assignment.roleDefinitionId}'
})]

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in formattedAssignments: {
    scope: keyVault::key
    name: guid(keyVault::key.id, assignment.principalId, assignment.roleDefinitionId)
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

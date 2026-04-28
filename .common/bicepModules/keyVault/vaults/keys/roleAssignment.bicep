import { roleAssignmentType } from '../../../types/roleAssignmentTypes.bicep'

param keyVaultName string
param keyName string

@description('Role assignments to apply to this key vault key.')
param assignments roleAssignmentType[]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName

  resource key 'keys' existing = {
    name: keyName
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in assignments: {
    scope: keyVault::key
    name: guid(keyVault::key.id, assignment.principalId, assignment.roleDefinitionId)
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

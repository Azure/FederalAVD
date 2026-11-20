metadata name = 'Virtual Network role assignments'
metadata description = 'Applies deterministic role assignments at an existing Virtual Network in the deployment resource group.'

import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@description('Name of the existing virtual network.')
param virtualNetworkName string

@description('Role assignments to apply to this virtual network.')
param assignments roleAssignmentType[]

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2026-03-01' existing = {
  name: virtualNetworkName
}

var formattedAssignments = [for assignment in assignments: union(assignment, {
  roleDefinitionId: contains(assignment.roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
    ? assignment.roleDefinitionId
    : '/providers/Microsoft.Authorization/roleDefinitions/${assignment.roleDefinitionId}'
})]

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in formattedAssignments: {
    scope: virtualNetwork
    name: guid(virtualNetwork.id, assignment.principalId, assignment.roleDefinitionId)
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

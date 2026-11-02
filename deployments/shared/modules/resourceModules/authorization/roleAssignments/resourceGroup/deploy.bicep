metadata name = 'Resource group role assignment'
metadata description = 'Assigns an existing role to a principal at the deployment resource group scope; the caller must have role-assignment permissions.'

// Example: "/providers/Microsoft.Authorization/roleDefinitions/c2f4ef07-...".
@description('Role definition GUID or fully-qualified resource ID.')
param roleDefinitionId string

@description('Principal ID of the identity receiving the role.')
param principalId string

@description('Principal type of the assigned principal.')
@allowed(['ServicePrincipal', 'Group', 'User', 'ForeignGroup', 'Device', ''])
param principalType string = 'ServicePrincipal'

@description('Optional description for the assignment.')
param assignmentDescription string = ''

var roleDefinitionIdVar = contains(roleDefinitionId, '/providers/Microsoft.Authorization/roleDefinitions/')
  ? roleDefinitionId
  : '/providers/Microsoft.Authorization/roleDefinitions/${roleDefinitionId}'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionIdVar)
  properties: {
    roleDefinitionId: roleDefinitionIdVar
    principalId: principalId
    principalType: !empty(principalType) ? principalType : null
    description: !empty(assignmentDescription) ? assignmentDescription : null
  }
}

@description('Resource ID of the resource group role assignment.')
output resourceId string = roleAssignment.id

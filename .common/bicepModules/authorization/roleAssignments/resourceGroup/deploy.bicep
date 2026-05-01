@description('Role definition GUID or fully-qualified resource ID (e.g. "/providers/Microsoft.Authorization/roleDefinitions/c2f4ef07-...").')
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

output resourceId string = roleAssignment.id

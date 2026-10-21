metadata name = 'Role assignment input type'
metadata description = 'Exports the role, principal and optional assignment details accepted by resource-scoped RBAC modules; does not assign permissions itself.'

// Shared type definitions for resource-scoped role assignments.
// Import in role assignment modules with:
//   import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@export()
@description('A single role assignment to apply to a specific resource.')
type roleAssignmentType = {
  // Examples: "b24988ac-..." or "/providers/Microsoft.Authorization/roleDefinitions/...".
  @description('Role definition GUID or fully-qualified resource ID.')
  roleDefinitionId: string

  @description('Object (principal) ID of the identity receiving the role.')
  principalId: string

  @description('Type of the assigned principal. Defaults to ServicePrincipal.')
  principalType: ('ServicePrincipal' | 'Group' | 'User' | 'ForeignGroup' | 'Device' | '')?

  @description('Optional human-readable description for the assignment.')
  description: string?
}

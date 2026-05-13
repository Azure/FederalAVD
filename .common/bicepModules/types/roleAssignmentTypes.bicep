// Shared type definitions for resource-scoped role assignments.
// Import in role assignment modules with:
//   import { roleAssignmentType } from '../../types/roleAssignmentTypes.bicep'

@export()
@description('A single role assignment to apply to a specific resource.')
type roleAssignmentType = {
  @description('Role definition GUID or fully-qualified resource ID (e.g. "b24988ac-..." or "/providers/Microsoft.Authorization/roleDefinitions/...").')
  roleDefinitionId: string

  @description('Object (principal) ID of the identity receiving the role.')
  principalId: string

  @description('Type of the assigned principal. Defaults to ServicePrincipal.')
  principalType: ('ServicePrincipal' | 'Group' | 'User' | 'ForeignGroup' | 'Device' | '')?

  @description('Optional human-readable description for the assignment.')
  description: string?
}

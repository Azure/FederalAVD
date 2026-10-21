metadata name = 'Microsoft Entra group input type'
metadata description = 'Exports the object ID and display-name shape used to reference existing Microsoft Entra groups; does not create or look up groups.'

// Shared identity-related input types.

@export()
@description('Reference to an existing Microsoft Entra group by object ID and display name.')
type entraGroupType = {
  @description('Microsoft Entra object ID of the group.')
  id: string

  @description('Display name of the group.')
  name: string
}
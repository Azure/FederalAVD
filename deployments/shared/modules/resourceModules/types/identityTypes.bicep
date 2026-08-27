// Shared identity-related input types.

@export()
type entraGroupType = {
  @description('Microsoft Entra object ID of the group.')
  id: string

  @description('Display name of the group.')
  name: string
}
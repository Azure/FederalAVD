@export()
type vmApplicationAssignmentType = {
  @description('Required. Azure Compute Gallery application version resource ID. Use an immutable semantic version or /versions/latest.')
  packageReferenceId: string

  @minValue(1)
  @maxValue(25)
  @description('Required. Application installation order.')
  order: int

  @description('Required. Whether an application lifecycle failure causes VM provisioning to report failure.')
  treatFailureAsDeploymentFailure: bool
}

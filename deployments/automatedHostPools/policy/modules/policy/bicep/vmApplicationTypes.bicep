@export()
type vmApplicationAssignmentType = {
  packageReferenceId: string
  @minValue(0)
  order: int
  treatFailureAsDeploymentFailure: bool
}
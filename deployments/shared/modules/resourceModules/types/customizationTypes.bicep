// Shared artifact customization and Run Command parameter types.

@export()
type artifactCustomizationType = {
  @description('Unique name for the customization.')
  name: string

  @description('Artifact blob path relative to the configured container, or a full HTTP or HTTPS URI.')
  blobNameOrUri: string

  @description('Optional arguments passed to the customization artifact.')
  arguments: string?

  @description('Optional comma-separated exit codes treated as success. Defaults to 0,3010.')
  successExitCodes: string?
}

@export()
type restartableArtifactCustomizationType = {
  @description('Unique name for the customization.')
  name: string

  @description('Artifact blob path relative to the configured container, or a full HTTP or HTTPS URI.')
  blobNameOrUri: string

  @description('Optional arguments passed to the customization artifact.')
  arguments: string?

  @description('Optional comma-separated exit codes treated as success. Defaults to 0,3010.')
  successExitCodes: string?

  @description('Restart the target virtual machine after the customization completes.')
  restart: bool?
}

@export()
type resolvedCustomizationType = {
  name: string
  uri: string
  arguments: string?
  successExitCodes: string?
  restart: bool
}

@export()
type runCommandParameterType = {
  name: string
  value: string
}

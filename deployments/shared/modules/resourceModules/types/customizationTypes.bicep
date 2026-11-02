metadata name = 'Artifact customization input types'
metadata description = 'Exports artifact, resolved customization and Run Command parameter shapes used by image and session-host customization workflows; does not deploy or execute artifacts.'

// Shared artifact customization and Run Command parameter types.

@export()
@description('Artifact reference and optional execution arguments or accepted exit codes for a named customization.')
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
@description('Artifact customization input with an optional post-execution VM restart request.')
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
@description('Resolved artifact URI and execution settings, including an explicit restart flag.')
type resolvedCustomizationType = {
  name: string
  uri: string
  arguments: string?
  successExitCodes: string?
  restart: bool
}

@export()
@description('Named string argument passed to a managed Run Command as a regular or protected parameter.')
type runCommandParameterType = {
  name: string
  value: string
}

// Compute-specific shared type definitions.
// Import in compute modules with:
//   import { extensionType } from '../types/computeTypes.bicep'

@export()
type extensionType = {
  @description('Extension resource name. Must be unique within the VM.')
  name: string

  @description('Extension handler publisher. E.g. Microsoft.Compute, Microsoft.Azure.Monitor.')
  publisher: string

  @description('Extension type name. E.g. JsonADDomainExtension, AzureMonitorWindowsAgent.')
  type: string

  @description('Major.minor version string. E.g. "1.3". autoUpgradeMinorVersion applies to the minor part.')
  typeHandlerVersion: string

  autoUpgradeMinorVersion: bool?
  enableAutomaticUpgrade: bool?

  @description('Change this value to force the extension to re-run on an already-deployed VM.')
  forceUpdateTag: string?

  @description('Extension-specific public settings object.')
  settings: object?

  @description('Extension-specific protected (secret) settings. Not logged or returned in ARM responses.')
  @secure()
  protectedSettings: object?

  suppressFailures: bool?

  @description('Optional. Names of other extensions in this array that must be provisioned before this one. ARM uses this to serialize extension deployment order within the same template.')
  provisionAfterExtensions: string[]?
}

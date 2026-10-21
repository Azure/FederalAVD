metadata name = 'Compute input types'
metadata description = 'Exports shared VM extension and gallery image replication input shapes. This type library does not deploy resources; consuming modules determine which optional fields are applied.'

// Compute-specific shared type definitions.
// Import in compute modules with:
//   import { extensionType } from '../types/computeTypes.bicep'

// Consuming modules determine which optional extension fields they forward to ARM.
@export()
@description('VM extension handler, upgrade options and public or protected settings.')
type extensionType = {
  @description('Extension resource name. Must be unique within the VM.')
  name: string

  // Examples: Microsoft.Compute, Microsoft.Azure.Monitor.
  @description('Extension handler publisher.')
  publisher: string

  // Examples: JsonADDomainExtension, AzureMonitorWindowsAgent.
  @description('Extension type name.')
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

  // When forwarded by the consuming module, ARM uses these names to serialize extension deployment
  // within the same template. Declaring the field in this type does not itself enforce execution order.
  @description('Optional. Names of extensions in the same array that must be provisioned before this one.')
  provisionAfterExtensions: string[]?
}

@export()
@description('Regional image replication settings, including optional replica count, storage type and disk encryption configuration.')
type galleryImageVersionTargetRegionType = {
  name: string
  regionalReplicaCount: int?
  storageAccountType: ('Standard_LRS' | 'Standard_ZRS' | 'Premium_LRS' | 'PremiumV2_LRS')?
  excludeFromLatest: bool?
  encryption: {
    osDiskImage: {
      diskEncryptionSetId: string?
      securityProfile: {
        confidentialVMEncryptionType: ('EncryptedVMGuestStateOnlyWithPmk' | 'EncryptedWithPmk' | 'EncryptedWithCmk' | 'NonPersistedTPM')?
        secureVMDiskEncryptionSetId: string?
      }?
    }?
  }?
}

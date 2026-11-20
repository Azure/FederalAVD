metadata name = 'Central naming bundle regression vectors'
metadata description = 'Evaluates current centralized host-pool and FSLogix functions across cloud and convention scenarios.'

import { hostPoolNames, fslogixNames, sharedServicesNames, imageManagementNames, resourceNameForType } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'
import { resourceName, imageStorageName, regionAbbreviation } from '../../deployments/shared/modules/orchestration/naming/internal.bicep'

@description('Optional. Selects an invalid workspace-subscription case for local runtime validation.')
param invalidCase string = ''

var profiles = loadJsonContent('./naming-bundles-cases.json')
func foundationContext(context object) object => {
  subscriptionId: context.subscriptionId
  cloud: context.cloud
  location: context.virtualMachinesLocation
}
func abbreviation(convention object, context object) string =>
  !empty(convention.?locationAbbreviation ?? '') ? convention.locationAbbreviation : regionAbbreviation(context.virtualMachinesLocation, context.cloud)

func expectedImageNames(convention object, context object, region string, groupName string) object => {
  resourceGroupName: groupName
  imageBuildResourceGroupName: resourceName(convention, 'imageBuildResourceGroup', region, 'image-management', '')
  galleryName: resourceName(convention, 'imageGallery', region, 'image-management', '')
  identityName: resourceName(convention, 'imageBlobIdentity', region, 'image-management', '')
  storageEncryptionIdentityName: resourceName(convention, 'imageStorageEncryptionIdentity', region, 'image-management', '')
  artifactsStorageAccountName: imageStorageName(convention, 'artifacts', region, union(foundationContext(context), { resourceGroupName: groupName }), '')
  logsStorageAccountName: imageStorageName(convention, 'logs', region, union(foundationContext(context), { resourceGroupName: groupName }), '')
  storageEncryptionKeyName: 'image-management-storage-cmk'
  galleryDiskEncryptionSetName: resourceName(convention, 'imageGalleryCustomerKeys', region, 'image-management', '')
  galleryDiskEncryptionKeyName: 'image-management-gallery-cmk'
  galleryConfidentialVmDiskEncryptionSetName: resourceName(convention, 'imageGalleryConfidentialKeys', region, 'image-management', '')
  galleryConfidentialVmDiskEncryptionKeyName: 'image-management-gallery-cvm-cmk'
}

var cases = map(profiles, profile => {
  name: profile.name
  hostPool: hostPoolNames(profile.convention, profile.identifier, union(profile.context, {
    existingFeedWorkspaceResourceId: invalidCase == 'workspace-subscription'
      ? '/subscriptions/other-subscription/resourceGroups/existing/providers/Microsoft.DesktopVirtualization/workspaces/feed'
      : profile.context.existingFeedWorkspaceResourceId
  }))
  fslogix: fslogixNames(profile.convention, profile.identifier, {
    subscriptionId: profile.context.subscriptionId
    cloud: profile.context.cloud
    location: profile.context.virtualMachinesLocation
  })
  sharedServices: sharedServicesNames(profile.convention, foundationContext(profile.context), {})
  imageManagement: imageManagementNames(profile.convention, foundationContext(profile.context), 'CustomerManaged')
  expectedImageManagement: expectedImageNames(profile.convention, profile.context, abbreviation(profile.convention, profile.context), resourceName(profile.convention, 'imageManagementResourceGroup', abbreviation(profile.convention, profile.context), 'image-management', ''))
  expectedVaultSeed: take(uniqueString(toLower(profile.context.subscriptionId), toLower(resourceName(profile.convention, 'operationsResourceGroup', abbreviation(profile.convention, profile.context), '', '')), toLower(profile.context.virtualMachinesLocation)), 6)
})

var context = foundationContext(profiles[0].context)
var explicitShared = sharedServicesNames({
  workload: 'overlength-workload'
  secretsKeyVaultNameOverride: 'convention-secrets'
  encryptionKeyVaultNameOverride: 'convention-encryption'
}, context, {
  consolidatedResourceGroupName: 'Existing-Operations'
  secretsKeyVaultName: 'explicit-secrets'
  encryptionKeyVaultName: 'explicit-encryption'
  controlPlaneResourceGroupName: 'ignored-control-plane'
  workspaceName: 'explicit-workspace'
  globalFeedResourceGroupName: 'explicit-feed-group'
  globalFeedWorkspaceName: 'explicit-feed'
})
var customImage = imageManagementNames({ imageManagementStoragePrefix: 'cont1', locationAbbreviation: 'e1' }, context, 'PlatformManagedAndCustomerManaged')
var lastImage = imageManagementNames({ components: ['workload', 'purpose', 'location', 'resourceType'], locationAbbreviation: 'e1' }, context, 'CustomerManaged')
var sharedAtLimit = sharedServicesNames({ workload: 'avdxxx' }, context, {})
var shared = sharedServicesNames({}, context, {})
var vaultContext = union(context, { resourceGroupName: shared.operationsResourceGroupName })
var scopeCases = [
  vaultContext
  union(vaultContext, { subscriptionId: '00000000-1111-2222-3333-555555555555' })
  union(vaultContext, { resourceGroupName: 'Existing-Operations' })
  union(vaultContext, { location: 'westus2' })
  union(vaultContext, { cloud: 'AzureUSGovernment' })
]
var aliasConventions = [
  { components: ['freeform1', 'purpose', 'freeform2', 'resourceType'], freeform1: 'org', freeform2: 'x' }
  { components: ['customToken1', 'purpose', 'customToken2', 'resourceType'], customToken1: 'org', customToken2: 'x' }
  { components: ['customToken1', 'purpose', 'freeform2', 'resourceType'], freeform1: 'org', customToken2: 'x' }
  { components: ['customToken1', 'purpose', 'customToken2', 'resourceType'], customToken1: 'org', freeform1: 'org', customToken2: 'x', freeform2: 'x' }
]

@description('Base64 transport preserves exact strings through the local CLI console renderer.')
output encodedResults string = base64(string(cases))

@description('Override and boundary cases for the foundation bundles.')
output encodedFoundation string = base64(string({
  explicitShared: explicitShared
  customImage: customImage
  lastImage: lastImage
  lastImageSeed: take(uniqueString(toLower(context.subscriptionId), toLower(lastImage.resourceGroupName), toLower(context.location)), 6)
  imageAtLimit: {
    artifacts: imageStorageName({}, 'artifacts', 'use2', union(context, { resourceGroupName: customImage.resourceGroupName }), 'cont1')
    logs: imageStorageName({}, 'logs', 'use2', union(context, { resourceGroupName: customImage.resourceGroupName }), 'cont1')
  }
  sharedAtLimit: sharedAtLimit
  customImageSeed: take(uniqueString(toLower(context.subscriptionId), toLower(customImage.resourceGroupName), toLower(context.location)), 6)
  consolidatedSeed: take(uniqueString(toLower(context.subscriptionId), 'existing-operations', toLower(context.location)), 6)
  consolidatedShared: sharedServicesNames({}, context, { consolidatedResourceGroupName: 'Existing-Operations' })
  shared: shared
  alternateHostPool: hostPoolNames({}, 'hr', profiles[0].context)
  directVaults: {
    secrets: resourceNameForType({}, 'keyVaults', 'sec', vaultContext)
    encryption: resourceNameForType({}, 'keyVaults', 'enc', vaultContext)
  }
  scopeCases: map(scopeCases, target => {
    hash: take(uniqueString(toLower(target.subscriptionId), toLower(target.resourceGroupName), toLower(target.location)), 6)
    secrets: resourceNameForType({ locationAbbreviation: 'e1' }, 'keyVaults', 'sec', target)
    encryption: resourceNameForType({ locationAbbreviation: 'e1' }, 'keyVaults', 'enc', target)
  })
  caseOnlyVault: resourceNameForType({}, 'keyVaults', 'SEC', {
    subscriptionId: toUpper(vaultContext.subscriptionId)
    resourceGroupName: toUpper(vaultContext.resourceGroupName)
    location: toUpper(vaultContext.location)
    cloud: toLower(vaultContext.cloud)
  })
  noLocationVault: resourceNameForType({ components: ['resourceType', 'workload', 'purpose'] }, 'keyVaults', 'sec', vaultContext)
  defaultImage: imageManagementNames({ locationAbbreviation: 'e1' }, context, 'CustomerManaged')
  aliasBundles: map(aliasConventions, convention => {
    hostPool: hostPoolNames(convention, 'finance', profiles[0].context)
    sharedServices: sharedServicesNames(convention, context, {})
    imageManagement: imageManagementNames(convention, context, 'CustomerManaged')
    directName: resourceNameForType(convention, 'applicationInsights', 'fin', vaultContext)
  })
}))

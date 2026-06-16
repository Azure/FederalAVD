targetScope = 'subscription'

// Deploys the Azure Virtual Desktop image management infrastructure: storage account for build artifacts,
// Azure Compute Gallery, and image definitions. Required before running any custom image build.

param location string = deployment().location

@description('Optional. Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name.')
param nameConvResTypeAtEnd bool = false

@description('Optional. Indicates whether the storage account permits requests to be authorized with the account access key via Shared Key. If false, then all requests, including shared access signatures, must be authorized with Azure Active Directory (Azure AD). The default value is null, which is equivalent to true.')
param storageAllowSharedKeyAccess bool = false

@description('Optional. The Resource Id of the Private DNS Zone where the Private Endpoint (if configured) A record will be registered.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Optional. Network access configuration for the artifacts storage account.')
@allowed([
  'PublicEndpoint'
  'PrivateEndpoint'
  'ServiceEndpoint'
])
param storageNetworkAccess string = 'PublicEndpoint'

@description('Optional. The ResourceId of the private endpoint subnet.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Array of permitted IPs or IP CIDR blocks that can access the storage account using the Public Endpoint.')
param storagePermittedIPs array = []

@description('Optional. An array of subnet resource IDs where Service Endpoints will be created to allow access to the storage account through the public endpoint.')
param storageServiceEndpointSubnetResourceIds array = []

@description('Optional. The tags by resource type to apply to the resources created by this template.')
param tags object = {}

// ── Artifacts Storage Account ─────────────────────────────────────────────────

@description('Optional. Deploy the artifacts storage account and managed identity. Set to false when you only need the gallery and all image customizations use fully-qualified public URIs or an externally-managed storage account.')
param deployArtifactsStorageAccount bool = true

// ── Customer-Managed Key parameters ──────────────────────────────────────────

@description('Optional. Key management for storage account encryption.')
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string = 'PlatformManaged'

@description('Optional. Key management for image encryption. Controls the Disk Encryption Set used for both gallery image version encryption and build VM OS disk encryption during image builds. CustomerManaged and CustomerManagedHSM use a single CMK layer. PlatformManagedAndCustomerManaged / PlatformManagedAndCustomerManagedHSM add a second platform-key layer underneath (double encryption). A DES is always created when any customer-managed option is selected. Pass the `diskEncryptionSetResourceId` output to imageBuild as `existingDiskEncryptionSetResourceId`.')
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
  'PlatformManagedAndCustomerManaged'
  'PlatformManagedAndCustomerManagedHSM'
])
param keyManagementGalleryImageVersions string = 'PlatformManaged'

@description('Optional. Resource ID of the Key Vault for CMK encryption. Required when keyManagementStorageAccounts or keyManagementGalleryImageVersions is not PlatformManaged.')
param encryptionKeyVaultResourceId string = ''

@description('Optional. Number of days before the CMK expires and auto-rotates.')
@minValue(7)
param keyExpirationInDays int = 180

@description('Optional. Deploy a Disk Encryption Set for Confidential VM gallery image versions (ConfidentialVmEncryptedWithCustomerKey). Requires a Premium Key Vault and the CVM Orchestrator service principal object ID. The CVM DES is always RSA-HSM backed (CustomerManagedHSM) regardless of the gallery key management selection. A standard gallery DES is always created alongside this. WARNING: The Confidential VM encryption key release policy is immutable once created — redeploying with this option enabled will fail if the key already exists. This is a one-time operation per region.')
param createConfidentialVmGalleryDes bool = false

@description('Optional. Object ID of the Confidential VM Orchestrator enterprise application (app ID: bf7b6499-ff71-4aa2-97a4-f372087be7f0). Required when createConfidentialVmGalleryDes is true.')
param confidentialVMOrchestratorObjectId string = ''

// ── Build Logs Storage Account ────────────────────────────────────────────────

@description('Optional. Deploy a dedicated storage account in the imageManagement resource group to persist image build customization logs. When enabled, pass the `buildLogsStorageAccountResourceId` output to imageBuild as `existingLogStorageAccountResourceId`.')
param deployBuildLogsStorageAccount bool = true

// ── Image Build Resource Group ─────────────────────────────────────────────────────

@description('Optional. Pre-create a persistent resource group dedicated to image builds and grant the managed identity Contributor on it. Enables image build operators who do not have subscription-level resource group creation rights to run image builds by pointing imageBuild to this resource group via imageBuildResourceGroupId. Disable only if all image build operators have sufficient permissions to create resource groups at the subscription level.')
param deployImageBuildResourceGroup bool = true

@description('Optional. Custom name for the pre-created image build resource group. Leave empty to use the standard naming convention (matches what imageBuild calculates automatically).')
param customImageBuildResourceGroupName string = ''

@description('Optional. Custom naming convention object produced by the portal UI. When provided, overrides the Cloud Adoption Framework naming convention for all image management resources. Shape: { segments: string[], separator: string, workload: string, freeform1: string, environment: string, freeform2: string, locationAbbreviation: string, resourceTypeCodes: { resourceGroups: string, computeGalleries: string, userAssignedIdentities: string, storageAccounts: string, privateEndpoints: string, networkInterfaces: string, diskEncryptionSets: string } }. Pass an empty object ({}) or omit to use the default CAF convention.')
param customNamingConvention object = {}

@description('DO NOT MODIFY THIS VALUE! The timestamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddhhmm')

// Naming conventions
var cloud = toLower(environment().name)
// account for air-gapped cloud location prefixes
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var locations = startsWith(cloud, 'us')
  ? (loadJsonContent('../../.common/data/locations.json')).other
  : (loadJsonContent('../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')

// ── Custom naming convention support ─────────────────────────────────────────
// When customNamingConvention is populated from the portal UI, build all resource names
// from the ordered segments array. When empty, fall through to the existing CAF logic.
var useCustomNaming = !empty(customNamingConvention) && contains(customNamingConvention, 'segments')

// Resolve per-convention values (safe to evaluate even when useCustomNaming = false)
var cnv_sep = useCustomNaming ? customNamingConvention.separator : '-'
var cnv_loc = useCustomNaming
  ? (!empty(customNamingConvention.locationAbbreviation)
      ? customNamingConvention.locationAbbreviation
      : locations[varLocation].abbreviation)
  : locations[varLocation].abbreviation
var cnv_rtCodes = useCustomNaming && contains(customNamingConvention, 'resourceTypeCodes')
  ? customNamingConvention.resourceTypeCodes
  : {
      resourceGroups: resourceAbbreviations.resourceGroups
      computeGalleries: resourceAbbreviations.computeGalleries
      userAssignedIdentities: resourceAbbreviations.userAssignedIdentities
      storageAccounts: resourceAbbreviations.storageAccounts
      privateEndpoints: resourceAbbreviations.privateEndpoints
      diskEncryptionSets: resourceAbbreviations.diskEncryptionSets
    }

// Resolve each segment value. 'resourceType' and 'purpose' use per-call placeholders; the
// others are fixed strings that can be resolved once here.
// Build one segment-value per slot (slot value = 'none' means stop).
var cnv_segments = useCustomNaming ? customNamingConvention.segments : []
// When custom naming is active, derive resource-type-first ordering from whether segment 1 is 'resourceType'.
// For the CAF fallback, this is the inverse of nameConvResTypeAtEnd.
// Used to ensure PE and NIC names follow the same prefix/suffix convention as all other resources.
var cnv_rtFirst = useCustomNaming ? (first(cnv_segments) == 'resourceType') : !nameConvResTypeAtEnd

// For a given resource type key (e.g. 'resourceGroups') and purpose string (e.g. 'image-management'),
// resolve a flat array of segment values then join with the separator.
// Bicep map() + filter() + join() replaces the CAF replace() chain.
func resolveSegment(seg string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  seg == 'resourceType' ? rtCode
    : seg == 'component' ? component
    : seg == 'location'  ? loc
    : seg == 'freeform1'     ? ff1
    : seg == 'environment'   ? env
    : seg == 'freeform2' ? ff2
    : seg == 'workload'  ? workload
    : '' // 'none' or unknown — filtered out below

func buildCustomName(segments array, sep string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(segments, seg => resolveSegment(seg, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    sep
  )

// Per-resource custom names (only used when useCustomNaming = true)
var customResourceGroupName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.resourceGroups,
      identifier,
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : ''

var customGalleryName = useCustomNaming
  ? replace(
      buildCustomName(
        filter(cnv_segments, s => s != 'none'),
        cnv_sep,
        cnv_rtCodes.computeGalleries,
        identifier,
        cnv_loc,
        customNamingConvention.?freeform1 ?? '',
        customNamingConvention.?environment ?? '',
        customNamingConvention.?freeform2 ?? '',
        customNamingConvention.?workload ?? ''
      ),
      '-',
      '_'
    )
  : ''

var customIdentityName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.userAssignedIdentities,
      identifier,
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : ''

var customEncryptionIdentityName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.userAssignedIdentities,
      '${identifier}-encryption',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : ''

// Storage account names: alphanumeric only, max 24 chars, globally unique.
// Apply custom convention as a prefix (separators stripped), then append uniqueString.
// Use short purpose tokens ('assets' / 'logs') to distinguish the two accounts and
// leave enough room for the uniqueString suffix to maintain global uniqueness.
func stripSeparators(s string) string =>
  replace(replace(replace(s, '-', ''), '_', ''), '.', '')

var customSaArtifactsBase = useCustomNaming
  ? stripSeparators(buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.storageAccounts,
      'assets',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    ))
  : ''

var customSaLogsBase = useCustomNaming
  ? stripSeparators(buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.storageAccounts,
      'logs',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    ))
  : ''

// ─────────────────────────────────────────────────────────────────────────────
var nameConv_Suffix_withoutResType = 'LOCATION'
var nameConvSuffix = nameConvResTypeAtEnd
  ? '${nameConv_Suffix_withoutResType}-RESOURCETYPE'
  : nameConv_Suffix_withoutResType
// 'image-management' is intentionally hardcoded — this solution always deploys a single
// shared environment and has no identifier or index parameter like host pool deployments.
var identifier = 'image-management'
var nameConv_ImageManagement_ResGroup = nameConvResTypeAtEnd
  ? 'avd-${identifier}-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var nameConv_ImageManagement_Resources = nameConvResTypeAtEnd
  ? 'avd-${identifier}-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var resourceGroupName = useCustomNaming
  ? customResourceGroupName
  : replace(
      replace(nameConv_ImageManagement_ResGroup, 'LOCATION', locations[varLocation].abbreviation),
      'RESOURCETYPE',
      resourceAbbreviations.resourceGroups
    )
// Image build RG name — matches the naming logic in imageBuild.bicep exactly so imageBuild
// deployments that omit imageBuildResourceGroupId will land in the pre-created RG automatically.
var imageBuildRgName = empty(customImageBuildResourceGroupName)
  ? nameConvResTypeAtEnd
      ? 'avd-image-builds-${locations[varLocation].abbreviation}-${resourceAbbreviations.resourceGroups}'
      : '${resourceAbbreviations.resourceGroups}-avd-image-builds-${locations[varLocation].abbreviation}'
  : customImageBuildResourceGroupName
var artifactsBlobContainerName = 'artifacts'
var galleryName = useCustomNaming
  ? customGalleryName
  : replace(
      replace(
        replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.computeGalleries),
        'LOCATION',
        locations[varLocation].abbreviation
      ),
      '-',
      '_'
    )
var identityName = useCustomNaming
  ? customIdentityName
  : replace(
      replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
      'LOCATION',
      locations[varLocation].abbreviation
    )
var vnetName = !empty(privateEndpointSubnetResourceId) ? split(privateEndpointSubnetResourceId, '/')[8] : ''
var privateEndpointNameConv = replace(
  '${cnv_rtFirst ? 'RESOURCETYPE-RESOURCE-SUBRESOURCE-${vnetName}' : 'RESOURCE-SUBRESOURCE-${vnetName}-RESOURCETYPE'}',
  'RESOURCETYPE',
  cnv_rtCodes.privateEndpoints
)
var privateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  artifactsStorageAccountName
)
var customNetworkInterfaceName = cnv_rtFirst
  ? '${cnv_rtCodes.?networkInterfaces ?? resourceAbbreviations.networkInterfaces}-${privateEndpointName}'
  : '${privateEndpointName}-${cnv_rtCodes.?networkInterfaces ?? resourceAbbreviations.networkInterfaces}'
// Unique suffix seed: add location when custom naming is active but the convention has no location
// segment, so deployments to different regions don't produce identical storage account names.
// CAF fallback already embeds the location abbreviation in the name itself, so no change needed there.
var saUniqueSuffix = (useCustomNaming && !contains(cnv_segments, 'location'))
  ? uniqueString(subscription().subscriptionId, resourceGroupName, location)
  : uniqueString(subscription().subscriptionId, resourceGroupName)
var artifactsStorageAccountName = take(
  useCustomNaming
    ? '${customSaArtifactsBase}${saUniqueSuffix}'
    : '${resourceAbbreviations.storageAccounts}imageassets${locations[varLocation].abbreviation}${saUniqueSuffix}',
  24
)
var sasExpirationPeriod = '180.00:00:00' // 180 days
var storageKind = 'StorageV2'
var storageSkuName = 'Standard_LRS'
// Both storage accounts use Hot tier: Cool's 30-day minimum applies to overwritten blob versions too (via versioning),
// so any Update-ImageArtifacts.ps1 run within 30 days of the last would incur early-deletion penalties on artifacts,
// and the 7-day log deletion would similarly penalize logs. Hot avoids both.
var artifactsStorageAccessTier = 'Hot'
var logsStorageAccessTier = 'Hot'

var storageEncryptionKeyName = '${identifier}-encryption-key-imagemgmt-storage'
// Single encryption UAI shared by both storage accounts.
// Result: uai-avd-image-management-encryption-{loc} (nameConvResTypeAtEnd=false)
//         avd-image-management-encryption-{loc}-uai  (nameConvResTypeAtEnd=true)
var storageEncryptionIdentityName = useCustomNaming
  ? customEncryptionIdentityName
  : replace(
      replace(
        replace(nameConv_ImageManagement_Resources, identifier, '${identifier}-encryption'),
        'RESOURCETYPE',
        resourceAbbreviations.userAssignedIdentities
      ),
      'LOCATION',
      locations[varLocation].abbreviation
    )
// Both storage accounts share the same key — no operational benefit to separate keys
// for same-solution, same-sensitivity storage in the same resource group.
var cmkKeyNames = (deployArtifactsStorageAccount || deployBuildLogsStorageAccount) ? [storageEncryptionKeyName] : []

// Disk encryption set names — one for standard CMK gallery encryption, one for Confidential VM DES.
// galleryDiskEncryptionKeyName / galleryConfidentialVmDiskEncryptionKeyName are Key Vault key names
// (not ARM resources) so they use a fixed descriptive format independent of the naming convention.
var galleryDiskEncryptionSetName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.diskEncryptionSets,
      contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : nameConvResTypeAtEnd
      ? 'image-management-${contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys'}-${locations[varLocation].abbreviation}-${resourceAbbreviations.diskEncryptionSets}'
      : '${resourceAbbreviations.diskEncryptionSets}-image-management-${contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys'}-${locations[varLocation].abbreviation}'
var galleryDiskEncryptionKeyName = '${identifier}-${locations[varLocation].abbreviation}-encryption-key-imagemgmt'

var galleryConfidentialVmDiskEncryptionSetName = useCustomNaming
  ? buildCustomName(
      filter(cnv_segments, s => s != 'none'),
      cnv_sep,
      cnv_rtCodes.diskEncryptionSets,
      'confidential-vm',
      cnv_loc,
      customNamingConvention.?freeform1 ?? '',
      customNamingConvention.?environment ?? '',
      customNamingConvention.?freeform2 ?? '',
      customNamingConvention.?workload ?? ''
    )
  : nameConvResTypeAtEnd
      ? 'image-management-confidential-vm-${locations[varLocation].abbreviation}-${resourceAbbreviations.diskEncryptionSets}'
      : '${resourceAbbreviations.diskEncryptionSets}-image-management-confidential-vm-${locations[varLocation].abbreviation}'
var galleryConfidentialVmDiskEncryptionKeyName = '${identifier}-${locations[varLocation].abbreviation}-encryption-key-imagemgmt-cvm'

var logsStorageName = take(
  useCustomNaming
    ? '${customSaLogsBase}${saUniqueSuffix}'
    : '${resourceAbbreviations.storageAccounts}imagelogs${locations[varLocation].abbreviation}${saUniqueSuffix}',
  24
)
var logsContainerName = 'image-customization-logs'
var logsPrivateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  logsStorageName
)
var logsCustomNetworkInterfaceName = cnv_rtFirst
  ? '${resourceAbbreviations.networkInterfaces}-${logsPrivateEndpointName}'
  : '${logsPrivateEndpointName}-${resourceAbbreviations.networkInterfaces}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags.?resourceGroups ?? {}
}

resource encryptionKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if ((keyManagementStorageAccounts != 'PlatformManaged' || keyManagementGalleryImageVersions != 'PlatformManaged' || createConfidentialVmGalleryDes) && !empty(encryptionKeyVaultResourceId)) {
  name: last(split(encryptionKeyVaultResourceId, '/'))
  scope: az.resourceGroup(split(encryptionKeyVaultResourceId, '/')[2], split(encryptionKeyVaultResourceId, '/')[4])
}

module imageGallery '../../.common/bicepModules/compute/galleries/deploy.bicep' = {
  name: 'Image-Gallery-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: galleryName
    location: location
    tags: tags[?'Microsoft.Compute/galleries'] ?? {}
  }
  dependsOn: [resourceGroup]
}

// Image Build Resource Group: pre-created so imageBuild deployments can reference it via
// imageBuildResourceGroupId without waiting for RG creation during the build.
module imageBuildResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = if (deployImageBuildResourceGroup) {
  name: 'Image-Build-ResourceGroup-${timeStamp}'
  params: {
    name: imageBuildRgName
    location: location
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// Grant the imageManagement UAI Contributor on the image build RG so it can create and manage
// build VMs, managed images, and all other resources without needing elevated subscription-level
// permissions. Contributor is required (over VM Contributor) because the cleanup script must also
// delete managed images (Microsoft.Compute/images/delete) which VM Contributor does not include.
module imageBuildRgContributorAssignment '../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (deployImageBuildResourceGroup) {
  name: 'RA-MI-Contributor-ImageBuildRG-${timeStamp}'
  scope: az.resourceGroup(imageBuildRgName)
  params: {
    principalId: managedIdentity!.outputs.principalId
    roleDefinitionId: 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
    principalType: 'ServicePrincipal'
  }
  dependsOn: [imageBuildResourceGroup]
}

module managedIdentity '../../.common/bicepModules/managedIdentity/userAssignedIdentities/deploy.bicep' = if (deployArtifactsStorageAccount || deployBuildLogsStorageAccount || deployImageBuildResourceGroup) {
  name: 'Managed-Identity-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: identityName
    location: location
    tags: tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
  }
  dependsOn: [resourceGroup]
}

// Single CMK module covering both storage accounts with a shared encryption UAI.
// CMK must complete before any storage account deployment so the role assignment
// propagates before the storage PUT includes the CMK reference.
module storageCmk '../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = if (keyManagementStorageAccounts != 'PlatformManaged' && (deployArtifactsStorageAccount || deployBuildLogsStorageAccount)) {
  name: 'Storage-CMK-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: keyManagementStorageAccounts == 'CustomerManagedHSM' ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: timeStamp
    keyNames: cmkKeyNames
    identityName: storageEncryptionIdentityName
  }
  dependsOn: [resourceGroup]
}

// DES for gallery image version encryption — created once here so imageBuild deployments
// can pass `diskEncryptionSetResourceId` as `existingDiskEncryptionSetResourceId`,
// suppressing per-build DES creation and KV dependency during image builds.
module diskCmk '../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = if (keyManagementGalleryImageVersions != 'PlatformManaged') {
  name: 'Disk-CMK-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: contains(keyManagementGalleryImageVersions, 'HSM')
      ? (contains(keyManagementGalleryImageVersions, 'Platform')
          ? 'PlatformManagedAndCustomerManagedHSM'
          : 'CustomerManagedHSM')
      : (contains(keyManagementGalleryImageVersions, 'Platform')
          ? 'PlatformManagedAndCustomerManaged'
          : 'CustomerManaged')
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: '${timeStamp}-gal'
    diskEncryptionConfigs: [
      {
        keyName: galleryDiskEncryptionKeyName
        diskEncryptionSetName: galleryDiskEncryptionSetName
        confidentialVMOSDiskEncryption: false
      }
    ]
  }
  dependsOn: [resourceGroup]
}

// DES for Confidential VM gallery image versions (ConfidentialVmEncryptedWithCustomerKey).
// Requires RSA-HSM key with key release policy — created via ARM on first deploy only.
// WARNING: The key release policy is immutable. Re-deploying with createConfidentialVmGalleryDes=true
// will fail if the key already exists. Disable this option on subsequent deployments.
module confidentialVmCmk '../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = if (createConfidentialVmGalleryDes) {
  name: 'ConfidentialVM-CMK-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: 'CustomerManagedHSM'
    location: location
    tags: tags
    deploymentSuffix: '${timeStamp}-cvm'
    diskEncryptionConfigs: [
      {
        keyName: galleryConfidentialVmDiskEncryptionKeyName
        diskEncryptionSetName: galleryConfidentialVmDiskEncryptionSetName
        confidentialVMOSDiskEncryption: true
        confidentialVMOrchestratorObjectId: confidentialVMOrchestratorObjectId
      }
    ]
  }
  dependsOn: [resourceGroup]
}

module assetsStorageAccount '../../.common/bicepModules/storage/storageAccounts/deploy.bicep' = if (deployArtifactsStorageAccount) {
  name: 'Assets-Storage-Account-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: artifactsStorageAccountName
    location: location
    kind: storageKind
    skuName: storageSkuName
    accessTier: artifactsStorageAccessTier
    allowSharedKeyAccess: storageAllowSharedKeyAccess
    requireInfrastructureEncryption: true
    permittedIPs: storagePermittedIPs
    serviceEndpointSubnetIds: storageServiceEndpointSubnetResourceIds
    publicNetworkAccess: (storageNetworkAccess == 'PrivateEndpoint' && empty(storagePermittedIPs) && empty(storageServiceEndpointSubnetResourceIds)) ? 'Disabled' : 'Enabled'
    networkAclsBypass: 'None'
    sasExpirationPeriod: sasExpirationPeriod
    cmkKeyUri: keyManagementStorageAccounts != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId)
      ? '${encryptionKeyVault!.properties.vaultUri}keys/${storageEncryptionKeyName}'
      : ''
    cmkUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
      ? storageCmk!.outputs.identityResourceId
      : ''
    tags: tags[?'Microsoft.Storage/storageAccounts'] ?? {}
  }
  dependsOn: [resourceGroup]
}

module assetsBlobService '../../.common/bicepModules/storage/storageAccounts/blobServices/deploy.bicep' = if (deployArtifactsStorageAccount) {
  name: 'Assets-Blob-Service-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: artifactsStorageAccountName
    deleteRetentionPolicyEnabled: true
    deleteRetentionPolicyDays: 7
    containerDeleteRetentionPolicyEnabled: true
    containerDeleteRetentionPolicyDays: 7
    versioningEnabled: false
    changeFeedEnabled: false
  }
  dependsOn: [assetsStorageAccount]
}

module assetsBlobContainer '../../.common/bicepModules/storage/storageAccounts/blobServices/containers/deploy.bicep' = if (deployArtifactsStorageAccount) {
  name: 'Assets-Blob-Container-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: artifactsStorageAccountName
    name: artifactsBlobContainerName
    publicAccess: 'None'
  }
  dependsOn: [assetsBlobService]
}

module assetsStoragePrivateEndpoint '../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deployArtifactsStorageAccount && storageNetworkAccess == 'PrivateEndpoint') {
  name: 'Assets-Storage-PE-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: privateEndpointName
    customNetworkInterfaceName: customNetworkInterfaceName
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: assetsStorageAccount!.outputs.resourceId
    groupId: 'blob'
    privateDNSZoneIds: !empty(azureBlobPrivateDnsZoneResourceId) ? [azureBlobPrivateDnsZoneResourceId] : []
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module assetsStorageBlobReaderAssignment '../../.common/bicepModules/storage/storageAccounts/roleAssignment.bicep' = if (deployArtifactsStorageAccount) {
  name: 'RA-MI-BlobReader-SA-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: artifactsStorageAccountName
    assignments: [
      {
        principalId: managedIdentity!.outputs.principalId
        roleDefinitionId: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' // Storage Blob Data Reader
        principalType: 'ServicePrincipal'
      }
    ]
  }
  dependsOn: [assetsStorageAccount]
}

// ── Build Logs Storage Account ────────────────────────────────────────────────

module logsStorageAccount '../../.common/bicepModules/storage/storageAccounts/deploy.bicep' = if (deployBuildLogsStorageAccount) {
  name: 'Logs-Storage-Account-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: logsStorageName
    location: location
    kind: storageKind
    skuName: storageSkuName
    accessTier: logsStorageAccessTier
    allowSharedKeyAccess: storageAllowSharedKeyAccess
    requireInfrastructureEncryption: true
    permittedIPs: storagePermittedIPs
    serviceEndpointSubnetIds: storageServiceEndpointSubnetResourceIds
    publicNetworkAccess: (storageNetworkAccess == 'PrivateEndpoint' && empty(storagePermittedIPs) && empty(storageServiceEndpointSubnetResourceIds)) ? 'Disabled' : 'Enabled'
    networkAclsBypass: 'None'
    sasExpirationPeriod: sasExpirationPeriod
    cmkKeyUri: keyManagementStorageAccounts != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId)
      ? '${encryptionKeyVault!.properties.vaultUri}keys/${storageEncryptionKeyName}'
      : ''
    cmkUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
      ? storageCmk!.outputs.identityResourceId
      : ''
    tags: tags[?'Microsoft.Storage/storageAccounts'] ?? {}
  }
  dependsOn: [resourceGroup]
}

module logsBlobService '../../.common/bicepModules/storage/storageAccounts/blobServices/deploy.bicep' = if (deployBuildLogsStorageAccount) {
  name: 'Logs-Blob-Service-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: logsStorageName
    deleteRetentionPolicyEnabled: false
    containerDeleteRetentionPolicyEnabled: false
  }
  dependsOn: [logsStorageAccount]
}

module logsStorageBlobContainer '../../.common/bicepModules/storage/storageAccounts/blobServices/containers/deploy.bicep' = if (deployBuildLogsStorageAccount) {
  name: 'Logs-Blob-Container-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: logsStorageName
    name: logsContainerName
    publicAccess: 'None'
  }
  dependsOn: [logsBlobService]
}

module logsStorageLifecyclePolicy '../../.common/bicepModules/storage/storageAccounts/managementPolicies/deploy.bicep' = if (deployBuildLogsStorageAccount) {
  name: 'Logs-Storage-LifecyclePolicy-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: logsStorageName
    rules: [
      {
        enabled: true
        name: 'Delete Blobs after 7 days'
        type: 'Lifecycle'
        definition: {
          actions: {
            baseBlob: {
              delete: {
                daysAfterModificationGreaterThan: 7
              }
            }
          }
          filters: {
            blobTypes: ['blockBlob', 'appendBlob']
          }
        }
      }
    ]
  }
  dependsOn: [logsStorageAccount]
}

module logsStoragePrivateEndpoint '../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deployBuildLogsStorageAccount && storageNetworkAccess == 'PrivateEndpoint') {
  name: 'Logs-Storage-PE-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: logsPrivateEndpointName
    customNetworkInterfaceName: logsCustomNetworkInterfaceName
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: logsStorageAccount!.outputs.resourceId
    groupId: 'blob'
    privateDNSZoneIds: !empty(azureBlobPrivateDnsZoneResourceId) ? [azureBlobPrivateDnsZoneResourceId] : []
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module logsStorageBlobContributorAssignment '../../.common/bicepModules/storage/storageAccounts/roleAssignment.bicep' = if (deployBuildLogsStorageAccount) {
  name: 'RA-MI-BlobContrib-LogsSA-${timeStamp}'
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: logsStorageName
    assignments: [
      {
        principalId: managedIdentity!.outputs.principalId
        roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
        principalType: 'ServicePrincipal'
      }
    ]
  }
  dependsOn: [logsStorageAccount]
}

output artifactsStorageAccountResourceId string = deployArtifactsStorageAccount
  ? assetsStorageAccount!.outputs.resourceId
  : ''
output artifactsBlobContainerName string = deployArtifactsStorageAccount ? assetsBlobContainer!.outputs.name : ''
output artifactsBlobContainerUrl string = deployArtifactsStorageAccount
  ? 'https://${artifactsStorageAccountName}.blob.${environment().suffixes.storage}/${artifactsBlobContainerName}'
  : ''
output managedIdentityResourceId string = (deployArtifactsStorageAccount || deployBuildLogsStorageAccount || deployImageBuildResourceGroup)
  ? managedIdentity!.outputs.resourceId
  : ''
output computeGalleryResourceId string = imageGallery!.outputs.resourceId
output buildLogsStorageAccountResourceId string = deployBuildLogsStorageAccount
  ? logsStorageAccount!.outputs.resourceId
  : ''
output buildLogsContainerUri string = deployBuildLogsStorageAccount
  ? 'https://${logsStorageName}.blob.${environment().suffixes.storage}/${logsContainerName}'
  : ''
output diskEncryptionSetResourceId string = keyManagementGalleryImageVersions != 'PlatformManaged'
  ? diskCmk!.outputs.diskResults[0].diskEncryptionSetResourceId
  : ''
output confidentialVmDiskEncryptionSetResourceId string = createConfidentialVmGalleryDes
  ? confidentialVmCmk!.outputs.diskResults[0].diskEncryptionSetResourceId
  : ''
output imageBuildResourceGroupResourceId string = deployImageBuildResourceGroup
  ? '/subscriptions/${subscription().subscriptionId}/resourceGroups/${imageBuildRgName}'
  : ''

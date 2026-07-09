targetScope = 'subscription'

// Deploys the Azure Virtual Desktop image management infrastructure: storage account for build artifacts,
// Azure Compute Gallery, and image definitions. Required before running any custom image build.

param location string = deployment().location

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

@description('''Optional. Naming convention controlling how all resources in this deployment are named.
The default value produces names aligned with the Cloud Adoption Framework (CAF) naming convention: resourceType-workload-purpose-location.
Note: 'purpose' is a FederalAVD addition with no direct CAF equivalent — it provides per-resource uniqueness within a deployment.
Component requirements:
  purpose      — REQUIRED. Multiple resources of the same type exist in this deployment (two storage accounts,
                 two UAIs, multiple DES). Without 'purpose' they produce identical names and the deployment fails.
  resourceType — Strongly recommended. Without it resource names carry no type identifier.
  location     — Optional. When omitted the location abbreviation is still embedded in storage account names
                 and added to unique-string seeds so cross-region deployments remain collision-free, but other
                 resource names will not contain a location segment.
  workload, freeform1, environment, freeform2 — Optional static tokens.
Key properties:
  components          — ordered array of name components, e.g. ["resourceType","workload","purpose","location"]
  delimiter           — character inserted between components, e.g. "-"
  workload            — solution identifier inserted into names, e.g. "avd"
  freeform1, environment, freeform2 — optional static/context tokens
  locationAbbreviation — override for the region abbreviation
  resourceTypeCodes   — object with per-resource-type abbreviation overrides
    { resourceGroups, computeGalleries, userAssignedIdentities, storageAccounts, privateEndpoints, networkInterfaces, diskEncryptionSets }
This object is produced automatically when deploying via the Azure Portal UI.
When deploying via ARM/Bicep CLI, omit to accept the defaults or override individual properties.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('DO NOT MODIFY THIS VALUE! The timestamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddhhmm')

// Naming conventions
// Override any component via the namingConvention parameter.
var cloud = toLower(environment().name)
// account for air-gapped cloud location prefixes
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var locations = startsWith(cloud, 'us')
  ? (loadJsonContent('../../.common/data/locations.json')).other
  : (loadJsonContent('../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')

// ── Naming convention ────────────────────────────────────────────────────────
// Default: Cloud Adoption Framework (CAF) — resourceType-workload-purpose-location.
// Override any component via the namingConvention parameter.

var cnv_delimiter      = namingConvention.?delimiter  ?? '-'
var cnv_loc      = !empty(namingConvention.?locationAbbreviation ?? '')
  ? namingConvention.locationAbbreviation
  : locations[varLocation].abbreviation
var cnv_rtCodes  = namingConvention.?resourceTypeCodes ?? {
  resourceGroups: resourceAbbreviations.resourceGroups
  computeGalleries: resourceAbbreviations.computeGalleries
  userAssignedIdentities: resourceAbbreviations.userAssignedIdentities
  storageAccounts: resourceAbbreviations.storageAccounts
  privateEndpoints: resourceAbbreviations.privateEndpoints
  diskEncryptionSets: resourceAbbreviations.diskEncryptionSets
}
var cnv_components = namingConvention.?components ?? ['resourceType', 'workload', 'purpose', 'location']
// RT is last only when resourceType is explicitly the last non-'none' component.
var cnv_rtFirst  = !empty(cnv_components) ? (last(filter(cnv_components, s => s != 'none')) != 'resourceType') : true

// For a given resource type key (e.g. 'resourceGroups') and purpose string (e.g. 'image-management'),
// resolve a flat array of component values then join with the delimiter.
// Bicep map() + filter() + join() replaces the CAF replace() chain.
func resolveComponent(comp string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  comp == 'resourceType' ? rtCode
    : comp == 'purpose' ? component
    : comp == 'location'  ? loc
    : comp == 'freeform1'     ? ff1
    : comp == 'environment'   ? env
    : comp == 'freeform2' ? ff2
    : comp == 'workload'  ? workload
    : '' // 'none' or unknown — filtered out below

func buildCustomName(components array, delimiter string, rtCode string, component string, loc string, ff1 string, env string, ff2 string, workload string) string =>
  join(
    filter(
      map(components, comp => resolveComponent(comp, rtCode, component, loc, ff1, env, ff2, workload)),
      s => !empty(s)
    ),
    delimiter
  )

// Per-resource names always built from cnv_components
var customResourceGroupName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.resourceGroups,
  identifier,
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var customGalleryName = replace(
  buildCustomName(
    filter(cnv_components, s => s != 'none'),
    cnv_delimiter,
    cnv_rtCodes.computeGalleries,
    identifier,
    cnv_loc,
    namingConvention.?freeform1 ?? '',
    namingConvention.?environment ?? '',
    namingConvention.?freeform2 ?? '',
    !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
  ),
  '-',
  '_'
)

var customIdentityName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.userAssignedIdentities,
  identifier,
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

var customEncryptionIdentityName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.userAssignedIdentities,
  '${identifier}-encryption',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)

// Storage account names: alphanumeric only, max 24 chars, globally unique.
// Pattern uses only RT abbreviation + purpose + location + uniqueString — no workload,
// environment, or freeform tokens. Those components eat into the 24-char budget at the
// expense of the uniqueness suffix without adding meaningful disambiguation (the
// containing resource group already carries the full convention name).
// RT position mirrors the convention: prefix when RT-first, suffix when RT-last.
var saRtCode = toLower(cnv_rtCodes.storageAccounts)  // e.g. 'sa'

// ─────────────────────────────────────────────────────────────────────────────
// 'image-management' is intentionally hardcoded — this solution always deploys a single
// shared environment and has no identifier or index parameter like host pool deployments.
var identifier = 'image-management'
var resourceGroupName = customResourceGroupName
// Image build RG: uses the same naming convention framework as all other resources.
// Purpose is 'image-builds' to distinguish it from the management RG ('image-management').
var imageBuildRgName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.resourceGroups,
  'image-builds',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)
var artifactsBlobContainerName = 'artifacts'
var galleryName = customGalleryName
var identityName = customIdentityName
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
// Unique suffix seed: add location when the convention has no location
// component, so deployments to different regions don't produce identical storage account names.
// CAF fallback already embeds the location abbreviation in the name itself, so no change needed there.
var saUniqueSuffix = !contains(cnv_components, 'location')
  ? uniqueString(subscription().subscriptionId, resourceGroupName, location)
  : uniqueString(subscription().subscriptionId, resourceGroupName)
// Fix the unique suffix length to the budget available for the longer purpose token ('imgassets' = 9
// chars) so both accounts always carry the same number of unique characters regardless of which
// account name is being built.
var saUniqueLen = 24 - length(saRtCode) - 9 - length(cnv_loc)
var saUnique    = take(saUniqueSuffix, saUniqueLen > 0 ? saUniqueLen : 1)
var artifactsStorageAccountName = cnv_rtFirst
  ? '${saRtCode}imgassets${cnv_loc}${saUnique}'
  : 'imgassets${cnv_loc}${saUnique}${saRtCode}'
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
// Result: uai-avd-image-management-encryption-{loc}
var storageEncryptionIdentityName = customEncryptionIdentityName
// Both storage accounts share the same key — no operational benefit to separate keys
// for same-solution, same-sensitivity storage in the same resource group.
var cmkKeyNames = (deployArtifactsStorageAccount || deployBuildLogsStorageAccount) ? [storageEncryptionKeyName] : []

// Disk encryption set names — one for standard CMK gallery encryption, one for Confidential VM DES.
// galleryDiskEncryptionKeyName / galleryConfidentialVmDiskEncryptionKeyName are Key Vault key names
// (not ARM resources) so they use a fixed descriptive format independent of the naming convention.
var galleryDiskEncryptionSetName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.diskEncryptionSets,
  contains(keyManagementGalleryImageVersions, 'Platform') ? '${identifier}-platform-and-customer-keys' : '${identifier}-customer-keys',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)
var galleryDiskEncryptionKeyName = '${identifier}-${locations[varLocation].abbreviation}-encryption-key-imagemgmt'

var galleryConfidentialVmDiskEncryptionSetName = buildCustomName(
  filter(cnv_components, s => s != 'none'),
  cnv_delimiter,
  cnv_rtCodes.diskEncryptionSets,
  '${identifier}-confidential-vm',
  cnv_loc,
  namingConvention.?freeform1 ?? '',
  namingConvention.?environment ?? '',
  namingConvention.?freeform2 ?? '',
  !empty(namingConvention.?workload ?? '') ? namingConvention.workload : 'avd'
)
var galleryConfidentialVmDiskEncryptionKeyName = '${identifier}-${locations[varLocation].abbreviation}-encryption-key-imagemgmt-cvm'

var logsStorageName = cnv_rtFirst
  ? '${saRtCode}imglogs${cnv_loc}${saUnique}'
  : 'imglogs${cnv_loc}${saUnique}${saRtCode}'
var logsContainerName = 'image-customization-logs'
var logsPrivateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  logsStorageName
)
var logsCustomNetworkInterfaceName = cnv_rtFirst
  ? '${cnv_rtCodes.?networkInterfaces ?? resourceAbbreviations.networkInterfaces}-${logsPrivateEndpointName}'
  : '${logsPrivateEndpointName}-${cnv_rtCodes.?networkInterfaces ?? resourceAbbreviations.networkInterfaces}'

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

// Network ACLs applied to all storage accounts in this deployment.
// bypass:'None' is intentional — image management storage does not require Azure service access.
// defaultAction falls back to 'Allow' only when no network restrictions are configured (dev/open scenario).
var storageHasNetworkRestrictions = !empty(storagePermittedIPs) || !empty(storageServiceEndpointSubnetResourceIds) || storageNetworkAccess == 'PrivateEndpoint'
var storageIpRules = [for ip in storagePermittedIPs: { value: ip, action: 'Allow' }]
var storageVnetRules = [for id in storageServiceEndpointSubnetResourceIds: { id: id, action: 'Allow' }]
var storageNetworkAcls = {
  bypass: 'None'
  defaultAction: storageHasNetworkRestrictions ? 'Deny' : 'Allow'
  ipRules: storageIpRules
  virtualNetworkRules: storageVnetRules
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
    networkAcls: storageNetworkAcls
    publicNetworkAccess: (storageNetworkAccess == 'PrivateEndpoint' && empty(storagePermittedIPs) && empty(storageServiceEndpointSubnetResourceIds)) ? 'Disabled' : 'Enabled'
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
    networkAcls: storageNetworkAcls
    publicNetworkAccess: (storageNetworkAccess == 'PrivateEndpoint' && empty(storagePermittedIPs) && empty(storageServiceEndpointSubnetResourceIds)) ? 'Disabled' : 'Enabled'
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

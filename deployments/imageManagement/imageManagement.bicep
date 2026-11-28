targetScope = 'subscription'

import { imageManagementNames, namingConventionConfig } from '../shared/modules/orchestration/naming/naming.bicep'
import { resolveNetworkAccess, serviceEndpointSubnetIds } from '../shared/modules/orchestration/networking/functions.bicep'
import { imageManagementPaasNetworkingType, sharedPrivateEndpointSubnetResourceIdsType, imageManagementPrivateDnsZoneResourceIdsType, resolvePaasNetworking, requirePrivateEndpointSubnet } from '../shared/modules/orchestration/networking/scenarios.bicep'

// Deploys the Azure Virtual Desktop image management infrastructure: storage account for build artifacts,
// Azure Compute Gallery, and image definitions. Required before running any custom image build.

param location string = deployment().location

@description('Optional. Indicates whether the storage account permits requests to be authorized with the account access key via Shared Key. If false, then all requests, including shared access signatures, must be authorized with Azure Active Directory (Azure AD). The default value is null, which is equivalent to true.')
param storageAllowSharedKeyAccess bool = false

@description('Optional. Common networking defaults and Storage overrides for artifacts and build logs. Omitted fields use private endpoints and disabled public access; IP and service-endpoint subnet allowlists remain independent.')
param paasNetworking imageManagementPaasNetworkingType = {}

@description('Conditional. Shared-resource private endpoint subnet. Required when private endpoints are selected for either created storage account; never falls back to public access.')
param privateEndpointSubnetResourceIds sharedPrivateEndpointSubnetResourceIdsType = {}

@description('Optional. Existing Blob private DNS zone resource ID. Empty omits the private endpoint DNS zone group.')
param privateDnsZoneResourceIds imageManagementPrivateDnsZoneResourceIdsType = {}

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

// Optional. Key management for image encryption. Controls the Disk Encryption Set used for both
// gallery image version encryption and build VM OS disk encryption during image builds.
// CustomerManaged and CustomerManagedHSM use a single CMK layer. PlatformManagedAndCustomerManaged /
// PlatformManagedAndCustomerManagedHSM add a second platform-key layer underneath (double encryption).
// A DES is always created when any customer-managed option is selected. Pass the
// `diskEncryptionSetResourceId` output to imageBuild as `existingDiskEncryptionSetResourceId`.
@description('Optional. Gallery image/build disk key-management mode. Customer-managed modes create a DES; pass its output to imageBuild as existingDiskEncryptionSetResourceId.')
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

@description('Optional. The resource ID of an existing Log Analytics Workspace for storage account diagnostic logs. Leave empty to skip diagnostic settings. See the Security & Monitoring deployment for an option to deploy a new workspace.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Number of days before the CMK expires and auto-rotates.')
@minValue(7)
param keyExpirationInDays int = 180

// Optional. Deploy a Disk Encryption Set for Confidential VM gallery image versions
// (ConfidentialVmEncryptedWithCustomerKey). Requires a Premium Key Vault and the CVM Orchestrator
// service principal object ID. The CVM DES is always RSA-HSM backed (CustomerManagedHSM) regardless of
// the gallery key management selection. A standard gallery DES is always created alongside this.
// WARNING: The Confidential VM encryption key release policy is immutable once created — redeploying
// with this option enabled will fail if the key already exists. This is a one-time operation per
// region.
@description('Optional. Create HSM-backed confidential-VM gallery DES alongside the standard DES. Requires Premium Key Vault and CVM Orchestrator; key release policy creation is one-time per region.')
param createConfidentialVmGalleryDes bool = false

@description('Optional. Object ID of the Confidential VM Orchestrator enterprise application (app ID: bf7b6499-ff71-4aa2-97a4-f372087be7f0). Required when createConfidentialVmGalleryDes is true.')
param confidentialVMOrchestratorObjectId string = ''

// ── Build Logs Storage Account ────────────────────────────────────────────────

// Optional. Deploy a dedicated storage account in the imageManagement resource group to persist image
// build customization logs. When enabled, pass the `buildLogsStorageAccountResourceId` output to
// imageBuild as `existingLogStorageAccountResourceId`.
@description('Optional. Create dedicated image-build log storage. Pass buildLogsStorageAccountResourceId to imageBuild as existingLogStorageAccountResourceId.')
param deployBuildLogsStorageAccount bool = true

// ── Image Build Resource Group ─────────────────────────────────────────────────────

// Optional. Pre-create a persistent resource group dedicated to image builds and grant the managed
// identity Contributor on it. Enables image build operators who do not have subscription-level
// resource group creation rights to run image builds by pointing imageBuild to this resource group via
// imageBuildResourceGroupId. Disable only if all image build operators have sufficient permissions to
// create resource groups at the subscription level.
@description('Optional. Pre-create the image-build resource group and grant its identity Contributor, enabling builds by operators without subscription-level resource-group creation rights.')
param deployImageBuildResourceGroup bool = true

// Optional. Naming convention controlling how all resources in this deployment are named.
// The default value produces names aligned with the Cloud Adoption Framework (CAF) naming convention:
// resourceType-workload-purpose-location.
// Note: 'purpose' is a FederalAVD addition with no direct CAF equivalent — it provides per-resource
// uniqueness within a deployment.
// Component requirements:
//   purpose      — REQUIRED. Multiple resources of the same type exist in this deployment (two storage accounts,
//                  two UAIs, multiple DES). Without 'purpose' they produce identical names and the deployment fails.
//   resourceType — Strongly recommended. Without it resource names carry no type identifier.
//   location     - Optional. Storage keeps its readable location token, and the full region
//                  always participates in the common scope hash. Other names omit this segment.
//   workload, freeform1, environment, freeform2 — Optional static tokens.
// Key properties:
//   components          — ordered array of name components, e.g. ["resourceType","workload","purpose","location"]
//   delimiter           — character inserted between components, e.g. "-"
//   workload            — solution identifier inserted into names, e.g. "avd"
//   freeform1, environment, freeform2 — optional static/context tokens
//   locationAbbreviation — override for the region abbreviation
//   imageManagementStoragePrefix — optional shared prefix for artifacts and build-logs storage accounts;
//                                  1-5 lowercase alphanumeric characters
//   resourceTypeCodes   — object with per-resource-type abbreviation overrides
//     { resourceGroups, computeGalleries, userAssignedIdentities, storageAccounts, privateEndpoints, networkInterfaces, diskEncryptionSets }
// This object is produced automatically when deploying via the Azure Portal UI.
// When deploying via ARM/Bicep CLI, omit to accept the defaults or override individual properties.
@description('Optional. Shared naming-convention overrides. Keep purpose to distinguish same-type resources; imageManagementStoragePrefix accepts 1-5 lowercase alphanumeric characters when supplied.')
param namingConvention namingConventionConfig = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

var storageCreated = deployArtifactsStorageAccount || deployBuildLogsStorageAccount
var resolvedNetworking = resolvePaasNetworking(paasNetworking, storageCreated, false, false)
var storagePublicNetworkAccess = resolvedNetworking.storage.publicNetworkAccess
var storagePrivateEndpoint = resolvedNetworking.storage.privateEndpoint
var storagePermittedIPs = resolvedNetworking.storage.permittedIPs
var storageServiceEndpointSubnetResourceIds = resolvedNetworking.storage.serviceEndpointSubnetResourceIds
var storagePrivateEndpointSubnetResourceId = requirePrivateEndpointSubnet(privateEndpointSubnetResourceIds.?sharedResources ?? '', storageCreated && storagePrivateEndpoint, 'sharedResources')
var blobPrivateDnsZoneResourceId = privateDnsZoneResourceIds.?blob ?? ''

var naming = imageManagementNames(namingConvention, {
  subscriptionId: subscription().subscriptionId
  cloud: environment().name
  location: location
}, keyManagementGalleryImageVersions)

var resourceGroupName = naming.resourceGroupName
var imageBuildRgName = naming.imageBuildResourceGroupName

var artifactsBlobContainerName = 'artifacts'
var galleryName = naming.galleryName
var identityName = naming.identityName
var vnetName = !empty(storagePrivateEndpointSubnetResourceId) ? split(storagePrivateEndpointSubnetResourceId, '/')[8] : ''
var privateEndpointNameConv = replace(naming.privateEndpointNameConv, 'VNETID', vnetName)

var privateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  artifactsStorageAccountName
)
var customNetworkInterfaceName = replace(replace(replace(naming.privateEndpointNICNameConv, 'VNETID', vnetName), 'SUBRESOURCE', 'blob'), 'RESOURCE', artifactsStorageAccountName)

// Both accounts share the owning-scope hash; their readable purposes distinguish them.
var artifactsStorageAccountName = naming.artifactsStorageAccountName

var sasExpirationPeriod = '180.00:00:00' // 180 days
var storageKind = 'StorageV2'
var storageSkuName = 'Standard_LRS'
// Both storage accounts use Hot tier: Cool's 30-day minimum applies to overwritten blob versions too (via versioning),
// so any Update-ImageArtifacts.ps1 run within 30 days of the last would incur early-deletion penalties on artifacts,
// and the 7-day log deletion would similarly penalize logs. Hot avoids both.
var artifactsStorageAccessTier = 'Hot'
var logsStorageAccessTier = 'Hot'

var storageEncryptionKeyName = naming.storageEncryptionKeyName

// Single encryption UAI shared by both storage accounts.
// Result: uai-avd-image-management-encryption-{loc}
var storageEncryptionIdentityName = naming.storageEncryptionIdentityName
// Both storage accounts share the same key — no operational benefit to separate keys
// for same-solution, same-sensitivity storage in the same resource group.
var cmkKeyNames = (deployArtifactsStorageAccount || deployBuildLogsStorageAccount) ? [storageEncryptionKeyName] : []

// Disk encryption set names — one for standard CMK gallery encryption, one for Confidential VM DES.
// galleryDiskEncryptionKeyName / galleryConfidentialVmDiskEncryptionKeyName are Key Vault key names
// (not ARM resources) so they use a fixed descriptive format independent of the naming convention.
var galleryDiskEncryptionSetName = naming.galleryDiskEncryptionSetName

var galleryDiskEncryptionKeyName = naming.galleryDiskEncryptionKeyName

var galleryConfidentialVmDiskEncryptionSetName = naming.galleryConfidentialVmDiskEncryptionSetName

var galleryConfidentialVmDiskEncryptionKeyName = naming.galleryConfidentialVmDiskEncryptionKeyName

var logsStorageName = naming.logsStorageAccountName

var logsContainerName = 'image-customization-logs'
var logsPrivateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  logsStorageName
)
var logsCustomNetworkInterfaceName = replace(replace(replace(naming.privateEndpointNICNameConv, 'VNETID', vnetName), 'SUBRESOURCE', 'blob'), 'RESOURCE', logsStorageName)

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags.?resourceGroups ?? {}
}

resource encryptionKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if ((keyManagementStorageAccounts != 'PlatformManaged' || keyManagementGalleryImageVersions != 'PlatformManaged' || createConfidentialVmGalleryDes) && !empty(encryptionKeyVaultResourceId)) {
  name: last(split(encryptionKeyVaultResourceId, '/'))
  scope: az.resourceGroup(split(encryptionKeyVaultResourceId, '/')[2], split(encryptionKeyVaultResourceId, '/')[4])
}

module imageGallery '../shared/modules/resourceModules/compute/galleries/deploy.bicep' = {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: galleryName
    location: location
    tags: tags[?'Microsoft.Compute/galleries'] ?? {}
    userAssignedIdentityResourceIds: deployArtifactsStorageAccount ? [managedIdentity!.outputs.resourceId] : []
  }
  dependsOn: [resourceGroup]
}

// Image Build Resource Group: pre-created so imageBuild deployments can reference it via
// imageBuildResourceGroupId without waiting for RG creation during the build.
module imageBuildResourceGroup '../shared/modules/resourceModules/resources/resourceGroups/deploy.bicep' = if (deployImageBuildResourceGroup) {
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
module imageBuildRgContributorAssignment '../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (deployImageBuildResourceGroup) {
  scope: az.resourceGroup(imageBuildRgName)
  params: {
    principalId: managedIdentity!.outputs.principalId
    roleDefinitionId: 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
    principalType: 'ServicePrincipal'
  }
  dependsOn: [imageBuildResourceGroup]
}

module managedIdentity '../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = if (deployArtifactsStorageAccount || deployBuildLogsStorageAccount || deployImageBuildResourceGroup) {
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
module storageCmk '../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = if (keyManagementStorageAccounts != 'PlatformManaged' && (deployArtifactsStorageAccount || deployBuildLogsStorageAccount)) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: keyManagementStorageAccounts == 'CustomerManagedHSM' ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    keyNames: cmkKeyNames
    identityName: storageEncryptionIdentityName
  }
  dependsOn: [resourceGroup]
}

// DES for gallery image version encryption — created once here so imageBuild deployments
// can pass `diskEncryptionSetResourceId` as `existingDiskEncryptionSetResourceId`,
// suppressing per-build DES creation and KV dependency during image builds.
module imageManagementDiskCmk '../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = if (keyManagementGalleryImageVersions != 'PlatformManaged') {
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
module confidentialVmCmk '../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = if (createConfidentialVmGalleryDes) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: 'CustomerManagedHSM'
    location: location
    tags: tags
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
// Azure Compute Gallery requires trusted-service access to ingest private VM Application packages.
var effectiveStoragePermittedIPs = filter(storagePermittedIPs, ip => !empty(trim(ip)))
var storageSubnetIds = serviceEndpointSubnetIds(storageServiceEndpointSubnetResourceIds)
var networkAccess = resolveNetworkAccess(
  storagePublicNetworkAccess,
  storagePrivateEndpoint,
  !empty(effectiveStoragePermittedIPs) || !empty(storageSubnetIds)
)
var storageIpRules = [for ip in effectiveStoragePermittedIPs: { value: ip, action: 'Allow' }]
var storageVnetRules = [for id in storageSubnetIds: { id: id, action: 'Allow' }]
var storageNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: networkAccess.defaultAction
  ipRules: storageIpRules
  virtualNetworkRules: storageVnetRules
}

module assetsStorageAccount '../shared/modules/resourceModules/storage/storageAccounts/deploy.bicep' = if (deployArtifactsStorageAccount) {
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
    publicNetworkAccess: networkAccess.publicNetworkAccess
    sasExpirationPeriod: sasExpirationPeriod
    cmkKeyUri: keyManagementStorageAccounts != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId)
      ? '${encryptionKeyVault!.properties.vaultUri}keys/${storageEncryptionKeyName}'
      : ''
    cmkUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
      ? storageCmk!.outputs.identityResourceId
      : ''
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    tags: tags[?'Microsoft.Storage/storageAccounts'] ?? {}
  }
  dependsOn: [resourceGroup]
}

module assetsBlobService '../shared/modules/resourceModules/storage/storageAccounts/blobServices/deploy.bicep' = if (deployArtifactsStorageAccount) {
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

module assetsBlobContainer '../shared/modules/resourceModules/storage/storageAccounts/blobServices/containers/deploy.bicep' = if (deployArtifactsStorageAccount) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: artifactsStorageAccountName
    name: artifactsBlobContainerName
    publicAccess: 'None'
  }
  dependsOn: [assetsBlobService]
}

module assetsStoragePrivateEndpoint '../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (deployArtifactsStorageAccount && storagePrivateEndpoint) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: privateEndpointName
    customNetworkInterfaceName: customNetworkInterfaceName
    location: location
    subnetResourceId: storagePrivateEndpointSubnetResourceId
    privateLinkServiceId: assetsStorageAccount!.outputs.resourceId
    groupId: 'blob'
    privateDNSZoneIds: !empty(blobPrivateDnsZoneResourceId) ? [blobPrivateDnsZoneResourceId] : []
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module assetsStorageBlobContributorAssignment '../shared/modules/resourceModules/storage/storageAccounts/roleAssignment.bicep' = if (deployArtifactsStorageAccount) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: artifactsStorageAccountName
    assignments: [
      {
        principalId: managedIdentity!.outputs.principalId
        roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
        principalType: 'ServicePrincipal'
      }
    ]
  }
  dependsOn: [assetsStorageAccount]
}

// ── Build Logs Storage Account ────────────────────────────────────────────────

module logsStorageAccount '../shared/modules/resourceModules/storage/storageAccounts/deploy.bicep' = if (deployBuildLogsStorageAccount) {
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
    publicNetworkAccess: networkAccess.publicNetworkAccess
    sasExpirationPeriod: sasExpirationPeriod
    cmkKeyUri: keyManagementStorageAccounts != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId)
      ? '${encryptionKeyVault!.properties.vaultUri}keys/${storageEncryptionKeyName}'
      : ''
    cmkUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
      ? storageCmk!.outputs.identityResourceId
      : ''
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    tags: tags[?'Microsoft.Storage/storageAccounts'] ?? {}
  }
  dependsOn: [resourceGroup]
}

module logsBlobService '../shared/modules/resourceModules/storage/storageAccounts/blobServices/deploy.bicep' = if (deployBuildLogsStorageAccount) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: logsStorageName
    deleteRetentionPolicyEnabled: false
    containerDeleteRetentionPolicyEnabled: false
  }
  dependsOn: [logsStorageAccount]
}

module logsStorageBlobContainer '../shared/modules/resourceModules/storage/storageAccounts/blobServices/containers/deploy.bicep' = if (deployBuildLogsStorageAccount) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    storageAccountName: logsStorageName
    name: logsContainerName
    publicAccess: 'None'
  }
  dependsOn: [logsBlobService]
}

module logsStorageLifecyclePolicy '../shared/modules/resourceModules/storage/storageAccounts/managementPolicies/deploy.bicep' = if (deployBuildLogsStorageAccount) {
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

module logsStoragePrivateEndpoint '../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (deployBuildLogsStorageAccount && storagePrivateEndpoint) {
  scope: az.resourceGroup(resourceGroupName)
  params: {
    name: logsPrivateEndpointName
    customNetworkInterfaceName: logsCustomNetworkInterfaceName
    location: location
    subnetResourceId: storagePrivateEndpointSubnetResourceId
    privateLinkServiceId: logsStorageAccount!.outputs.resourceId
    groupId: 'blob'
    privateDNSZoneIds: !empty(blobPrivateDnsZoneResourceId) ? [blobPrivateDnsZoneResourceId] : []
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module logsStorageBlobContributorAssignment '../shared/modules/resourceModules/storage/storageAccounts/roleAssignment.bicep' = if (deployBuildLogsStorageAccount) {
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
  ? imageManagementDiskCmk!.outputs.diskResults[0].diskEncryptionSetResourceId
  : ''
output confidentialVmDiskEncryptionSetResourceId string = createConfidentialVmGalleryDes
  ? confidentialVmCmk!.outputs.diskResults[0].diskEncryptionSetResourceId
  : ''
output imageBuildResourceGroupResourceId string = deployImageBuildResourceGroup
  ? '/subscriptions/${subscription().subscriptionId}/resourceGroups/${imageBuildRgName}'
  : ''

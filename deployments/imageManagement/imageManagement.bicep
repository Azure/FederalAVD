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
param deployBuildLogsStorageAccount bool = false

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
var nameConv_Suffix_withoutResType = 'LOCATION'
var nameConvSuffix = nameConvResTypeAtEnd
  ? '${nameConv_Suffix_withoutResType}-RESOURCETYPE'
  : nameConv_Suffix_withoutResType
var identifier = 'image-management'
var nameConv_ImageManagement_ResGroup = nameConvResTypeAtEnd
  ? 'avd-${identifier}-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var nameConv_ImageManagement_Resources = nameConvResTypeAtEnd
  ? 'avd-${identifier}-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-${identifier}-${nameConvSuffix}'
var resourceGroupName = replace(
  replace(nameConv_ImageManagement_ResGroup, 'LOCATION', locations[varLocation].abbreviation),
  'RESOURCETYPE',
  resourceAbbreviations.resourceGroups
)
var artifactsBlobContainerName = 'artifacts'
var galleryName = replace(
  replace(
    replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.computeGalleries),
    'LOCATION',
    locations[varLocation].abbreviation
  ),
  '-',
  '_'
)
var identityName = replace(
  replace(nameConv_ImageManagement_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
  'LOCATION',
  locations[varLocation].abbreviation
)
var vnetName = !empty(privateEndpointSubnetResourceId) ? split(privateEndpointSubnetResourceId, '/')[8] : ''
var privateEndpointNameConv = replace(
  '${nameConvResTypeAtEnd ? 'RESOURCE-SUBRESOURCE-${vnetName}-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-${vnetName}'}',
  'RESOURCETYPE',
  resourceAbbreviations.privateEndpoints
)
var privateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  artifactsStorageAccountName
)
var customNetworkInterfaceName = nameConvResTypeAtEnd
  ? '${privateEndpointName}-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${privateEndpointName}'
var artifactsStorageAccountName = take(
  '${resourceAbbreviations.storageAccounts}imageassets${locations[varLocation].abbreviation}${uniqueString(subscription().subscriptionId, resourceGroupName)}',
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
var storageEncryptionIdentityName = replace(
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

var galleryDiskEncryptionSetName = nameConvResTypeAtEnd
  ? 'image-management-${contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys'}-${locations[varLocation].abbreviation}-${resourceAbbreviations.diskEncryptionSets}'
  : '${resourceAbbreviations.diskEncryptionSets}-image-management-${contains(keyManagementGalleryImageVersions, 'Platform') ? 'platform-and-customer-keys' : 'customer-keys'}-${locations[varLocation].abbreviation}'
var galleryDiskEncryptionKeyName = '${identifier}-${locations[varLocation].abbreviation}-encryption-key-imagemgmt'

var galleryConfidentialVmDiskEncryptionSetName = nameConvResTypeAtEnd
  ? 'image-management-confidential-vm-${locations[varLocation].abbreviation}-${resourceAbbreviations.diskEncryptionSets}'
  : '${resourceAbbreviations.diskEncryptionSets}-image-management-confidential-vm-${locations[varLocation].abbreviation}'
var galleryConfidentialVmDiskEncryptionKeyName = '${identifier}-${locations[varLocation].abbreviation}-encryption-key-imagemgmt-cvm'

var logsStorageName = take(
  '${resourceAbbreviations.storageAccounts}imagelogs${locations[varLocation].abbreviation}${uniqueString(subscription().subscriptionId, resourceGroupName)}',
  24
)
var logsContainerName = 'image-customization-logs'
var logsPrivateEndpointName = replace(
  replace(privateEndpointNameConv, 'SUBRESOURCE', 'blob'),
  'RESOURCE',
  logsStorageName
)
var logsCustomNetworkInterfaceName = nameConvResTypeAtEnd
  ? '${logsPrivateEndpointName}-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${logsPrivateEndpointName}'

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

module managedIdentity '../../.common/bicepModules/managedIdentity/userAssignedIdentities/deploy.bicep' = if (deployArtifactsStorageAccount || deployBuildLogsStorageAccount) {
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
    storageKeyNames: cmkKeyNames
    storageIdentityName: storageEncryptionIdentityName
  }
  dependsOn: [resourceGroup]
}

// DES for gallery image version encryption — created once here so imageBuild deployments
// can pass `diskEncryptionSetResourceId` as `existingDiskEncryptionSetResourceId`,
// suppressing per-build DES creation and KV dependency during image builds.
module diskCmk '../hostpools/modules/diskCmk/diskCmk.bicep' = if (keyManagementGalleryImageVersions != 'PlatformManaged') {
  name: 'Disk-CMK-${timeStamp}'
  scope: subscription()
  params: {
    resourceGroupName: resourceGroupName
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
    keyName: galleryDiskEncryptionKeyName
    diskEncryptionSetName: galleryDiskEncryptionSetName
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
    privateEndpoint: storageNetworkAccess == 'PrivateEndpoint'
    networkAclsBypass: 'None'
    sasExpirationPeriod: sasExpirationPeriod
    encryptionKeyVaultUri: keyManagementStorageAccounts != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId)
      ? encryptionKeyVault!.properties.vaultUri
      : ''
    encryptionKeyName: keyManagementStorageAccounts != 'PlatformManaged' ? storageEncryptionKeyName : ''
    encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
      ? storageCmk!.outputs.storageIdentityResourceId
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
    privateEndpoint: storageNetworkAccess == 'PrivateEndpoint'
    networkAclsBypass: 'None'
    sasExpirationPeriod: sasExpirationPeriod
    encryptionKeyVaultUri: keyManagementStorageAccounts != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId)
      ? encryptionKeyVault!.properties.vaultUri
      : ''
    encryptionKeyName: keyManagementStorageAccounts != 'PlatformManaged' ? storageEncryptionKeyName : ''
    encryptionUserAssignedIdentityResourceId: keyManagementStorageAccounts != 'PlatformManaged'
      ? storageCmk!.outputs.storageIdentityResourceId
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
output managedIdentityResourceId string = (deployArtifactsStorageAccount || deployBuildLogsStorageAccount)
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
  ? diskCmk!.outputs.diskEncryptionSetResourceId
  : ''
output confidentialVmDiskEncryptionSetResourceId string = createConfidentialVmGalleryDes
  ? confidentialVmCmk!.outputs.diskResults[0].diskEncryptionSetResourceId
  : ''

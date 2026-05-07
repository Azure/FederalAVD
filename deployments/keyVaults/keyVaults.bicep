targetScope = 'subscription'

// Deploys the AVD Key Vault prerequisites into the operations resource group: a Secrets Key Vault for
// credentials (domain join, VM admin) and an Encryption Key Vault for Customer Managed Key (CMK) encryption.
// Deploy this before any AVD solution that uses CMK or references a pre-provisioned credentials Key Vault.

// ── Location & Naming ──────────────────────────────────────────────────────────

@description('Required. The Azure region for all foundation resources.')
param location string = deployment().location

@description('Optional. Reverse the normal Cloud Adoption Framework naming convention by putting the resource type abbreviation at the end of the resource name.')
param nameConvResTypeAtEnd bool = false

// ── Secrets Key Vault ──────────────────────────────────────────────────────────

@description('Optional. Deploy the Secrets Key Vault (Standard SKU) for storing AVD credentials (VM admin password, domain join credentials).')
param deploySecretsKeyVault bool = true

@description('Optional. Enable soft delete on the Secrets Key Vault.')
param secretsKeyVaultEnableSoftDelete bool = true

@description('Optional. Enable purge protection on the Secrets Key Vault. Recommended for production environments.')
param secretsKeyVaultEnablePurgeProtection bool = true

@description('Optional. The retention period in days for soft-deleted objects in the Key Vaults.')
@minValue(7)
@maxValue(90)
param keyVaultRetentionInDays int = 7

// ── Credential Secrets (Optional — Security Team Owned) ───────────────────────
// Providing these values stores them in the Secrets Key Vault at foundation deployment time.
// Solution deployers (host pool, add-ons) only need the KV resource ID as a reference —
// they do not require read/write access to the secrets themselves.
// NOTE: If using ARM getSecret() references in downstream deployments, the deploying identity
// requires the 'Key Vault Secrets User' role on the Secrets Key Vault.

@secure()
@description('Optional. Virtual machine local administrator password. Stored as VirtualMachineAdminPassword in the Secrets Key Vault.')
param virtualMachineAdminPassword string = ''

@secure()
@description('Optional. Virtual machine local administrator username. Stored as VirtualMachineAdminUserName in the Secrets Key Vault.')
param virtualMachineAdminUserName string = ''

@secure()
@description('Optional. Domain join user password. Stored as DomainJoinUserPassword in the Secrets Key Vault.')
param domainJoinUserPassword string = ''

@secure()
@description('Optional. Domain join user principal name (UPN). Stored as DomainJoinUserPrincipalName in the Secrets Key Vault.')
param domainJoinUserPrincipalName string = ''

// ── Encryption Key Vault ───────────────────────────────────────────────────────
// Required for all AVD solutions using Customer-Managed Keys:
//   - Host Pool (disk encryption sets, FSLogix storage)
//   - Image Management (artifacts storage)
//   - Image Build (logs storage)
//   - Session Host Replacer / Storage Quota Manager (function app storage)
//
// REQUIRED RBAC for deploying identities on this Key Vault:
//   - 'Key Vault Crypto Officer' role — required to create encryption keys via the CMK module.
//     This role is needed at deployment time only; it can be removed after initial key creation
//     if key rotation is handled separately.

@description('Optional. Deploy the Encryption Key Vault (Premium SKU) for Customer-Managed Keys. Required when using CMK in any AVD solution.')
param deployEncryptionKeyVault bool = true

// ── Private Endpoints ──────────────────────────────────────────────────────────

@description('Optional. Deploy private endpoints for the Key Vaults. When true, public network access is disabled on both Key Vaults.')
param privateEndpoint bool = false

@description('Conditional. The resource ID of the subnet for Key Vault private endpoints. Required when privateEndpoint is true.')
param privateEndpointSubnetResourceId string = ''

@description('Conditional. The resource ID of the Azure Key Vault Private DNS Zone. Required when privateEndpoint is true.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

// ── Monitoring ─────────────────────────────────────────────────────────────────

@description('Optional. The resource ID of an existing Log Analytics Workspace for Key Vault diagnostic logs.')
param logAnalyticsWorkspaceResourceId string = ''

// ── Tags ───────────────────────────────────────────────────────────────────────

@description('Optional. Tags to apply to deployed resources, keyed by resource type (e.g., "Microsoft.KeyVault/vaults", "Microsoft.Resources/resourceGroups").')
param tags object = {}

// ── Non-Specified Values ───────────────────────────────────────────────────────

@description('DO NOT MODIFY THIS VALUE! The timestamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timeStamp string = utcNow('yyyyMMddHHmmss')

// ── Naming Convention ──────────────────────────────────────────────────────────

var cloud = toLower(environment().name)
// Account for air-gapped cloud location prefixes (us-gov, us-sec, etc.)
#disable-next-line BCP329
var varLocation = startsWith(cloud, 'us') ? substring(location, 5, length(location) - 5) : location
var locations = startsWith(cloud, 'us')
  ? (loadJsonContent('../../.common/data/locations.json')).other
  : (loadJsonContent('../../.common/data/locations.json'))[environment().name]
var resourceAbbreviations = loadJsonContent('../../.common/data/resourceAbbreviations.json')

var deploymentSuffix = timeStamp
var identifier = 'operations'

#disable-next-line BCP329
var locationAbbreviation = locations[varLocation].abbreviation

// Resource group naming: rg-avd-foundation-eus (not reversed) or avd-foundation-eus-rg (reversed)
var nameConv_Operations_ResGroup = nameConvResTypeAtEnd
  ? 'avd-${identifier}-LOCATION-RESOURCETYPE'
  : 'RESOURCETYPE-avd-${identifier}-LOCATION'

// Shared resource naming with TOKEN placeholder for sub-type differentiation (sec, enc)
var nameConv_Operations_Resources = nameConvResTypeAtEnd
  ? 'avd-TOKEN-LOCATION-RESOURCETYPE'
  : 'RESOURCETYPE-avd-TOKEN-LOCATION'

// Private endpoint naming conventions
var privateEndpointNameConv = nameConvResTypeAtEnd
  ? 'RESOURCE-SUBRESOURCE-VNETID-${resourceAbbreviations.privateEndpoints}'
  : '${resourceAbbreviations.privateEndpoints}-RESOURCE-SUBRESOURCE-VNETID'
var privateEndpointNICNameConv = nameConvResTypeAtEnd
  ? 'RESOURCE-SUBRESOURCE-VNETID-${resourceAbbreviations.privateEndpoints}-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${resourceAbbreviations.privateEndpoints}-RESOURCE-SUBRESOURCE-VNETID'

var operationsResourceGroupName = replace(
  replace(nameConv_Operations_ResGroup, 'LOCATION', locationAbbreviation),
  'RESOURCETYPE',
  resourceAbbreviations.resourceGroups
)

// Stable 6-char unique string seeded on subscription + resource group name (consistent across re-deployments)
var uniqueStringOperations = take(uniqueString(subscription().subscriptionId, operationsResourceGroupName), 6)

// Key Vault names are capped at 24 chars to satisfy Azure naming constraints
var secretsKeyVaultName = take(
  replace(
    replace(
      replace(nameConv_Operations_Resources, 'TOKEN', 'sec-${uniqueStringOperations}'),
      'LOCATION',
      locationAbbreviation
    ),
    'RESOURCETYPE',
    resourceAbbreviations.keyVaults
  ),
  24
)

var encryptionKeyVaultName = take(
  replace(
    replace(
      replace(nameConv_Operations_Resources, 'TOKEN', 'enc-${uniqueStringOperations}'),
      'LOCATION',
      locationAbbreviation
    ),
    'RESOURCETYPE',
    resourceAbbreviations.keyVaults
  ),
  24
)

// ── Resource Group ─────────────────────────────────────────────────────────────

module operationsResourceGroup '../../.common/bicepModules/resources/resourceGroups/deploy.bicep' = {
  name: 'Operations-ResourceGroup-${deploymentSuffix}'
  scope: subscription()
  params: {
    location: location
    name: operationsResourceGroupName
    tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {}
  }
}

// ── Key Vaults ─────────────────────────────────────────────────────────────────

module keyVaults '../../.common/bicepModules/custom/keyVaults/keyVaults.bicep' = {
  name: 'Operations-KeyVaults-${deploymentSuffix}'
  scope: subscription()
  params: {
    resourceGroupName: operationsResourceGroupName
    deploySecretsKeyVault: deploySecretsKeyVault
    secretsKeyVaultName: secretsKeyVaultName
    keyVaultEnableSoftDelete: secretsKeyVaultEnableSoftDelete
    keyVaultEnablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    keyVaultRetentionInDays: keyVaultRetentionInDays
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    deployEncryptionKeyVault: deployEncryptionKeyVault
    encryptionKeyVaultName: encryptionKeyVaultName
    privateEndpoint: privateEndpoint
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    azureKeyVaultPrivateDnsZoneResourceId: azureKeyVaultPrivateDnsZoneResourceId
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: tags
    deploymentSuffix: deploymentSuffix
  }
  dependsOn: [operationsResourceGroup]
}

// ── Outputs ────────────────────────────────────────────────────────────────────

@description('The name of the security resource group.')
output resourceGroupName string = operationsResourceGroupName

@description('The name of the Secrets Key Vault. Empty if not deployed.')
output secretsKeyVaultName string = deploySecretsKeyVault ? secretsKeyVaultName : ''

@description('The resource ID of the Secrets Key Vault. Pass as "credentialsKeyVaultResourceId" to the host pool and Session Host Replacer deployments.')
output secretsKeyVaultResourceId string = deploySecretsKeyVault ? keyVaults.outputs.secretsKeyVaultResourceId : ''

@description('The name of the Encryption Key Vault. Empty if not deployed.')
output encryptionKeyVaultName string = deployEncryptionKeyVault ? encryptionKeyVaultName : ''

@description('The resource ID of the Encryption Key Vault. Pass as "encryptionKeyVaultResourceId" to any AVD solution using Customer-Managed Keys.')
output encryptionKeyVaultResourceId string = deployEncryptionKeyVault ? keyVaults.outputs.encryptionKeyVaultResourceId : ''

@description('The URI of the Encryption Key Vault.')
output encryptionKeyVaultUri string = deployEncryptionKeyVault ? keyVaults.outputs.encryptionKeyVaultUri : ''

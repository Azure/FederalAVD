targetScope = 'subscription'

// ─────────────────────────────────────────────────────────────────────────────
// Recovery Services — per-hostpool VM-backup vault in the Hosts resource group.
//
// Only deployed for Personal host pools (VM backup). Pooled host pool storage
// backup uses Azure Files soft delete and snapshots instead.
//
// createVault = false when reusing an existing vault (existingRecoveryServicesVaultResourceId).
// ─────────────────────────────────────────────────────────────────────────────

@description('Required. When true, a new Recovery Services Vault is created. When false, an existing vault is used via existingRecoveryServicesVaultResourceId.')
param createVault bool

@description('Conditional. Resource ID of an existing Recovery Services Vault. Required when createVault is false.')
param existingRecoveryServicesVaultResourceId string = ''

@description('Required. Name for the Recovery Services Vault (used only when createVault is true).')
param vaultName string

@description('Required. Name of the hosts resource group where the vault is (or will be) deployed.')
param resourceGroupHosts string

@description('Required. Azure region for all resources.')
param location string

@description('Required. Storage replication type for a new vault: LocallyRedundant, GeoRedundant, or ZoneRedundant.')
param storageRedundancy string

// CRR is enabled automatically when GRS is selected. GRS storage costs the same
// regardless of whether CRR is on, and without CRR the geo-redundant copy provides
// passive durability only with no recovery capability in the secondary region.
var crossRegionRestoreEnabled = storageRedundancy == 'GeoRedundant'

@description('Required. Short unique deployment suffix.')
param deploymentSuffix string

@description('Optional. Resource ID of the Log Analytics workspace for vault diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. Whether to deploy private endpoints for the vault.')
param privateEndpoint bool

@description('Optional. Resource ID of the subnet for the vault private endpoint.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Resource ID of the Azure Backup private DNS zone.')
param azureBackupPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Blob private DNS zone (needed for backup PE).')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Queue private DNS zone (needed for backup PE).')
param azureQueuePrivateDnsZoneResourceId string = ''

@description('Required. Name convention for private endpoints.')
param privateEndpointNameConv string

@description('Required. Name convention for private endpoint NICs.')
param privateEndpointNICNameConv string

@description('Required. Resource tags object.')
param tags object

@description('Required. Backup policy time zone (e.g. "Eastern Standard Time").')
param timeZone string

param vmPolicyName string = 'AvdPolicyVm'

@description('Optional. Number of daily VM recovery points to retain (1–365).')
@minValue(1)
@maxValue(365)
param backupRetentionDays int = 30

@description('Optional. Shared key management mode for PaaS resources. When set to CustomerManaged or CustomerManagedHSM and createVault is true, vault CMK is configured.')
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementType string = 'PlatformManaged'

@description('Optional. Resource ID of the encryption key vault used for vault CMK configuration.')
param encryptionKeyVaultResourceId string = ''

@description('Optional. URI of the encryption key vault used for vault CMK configuration.')
param encryptionKeyVaultUri string = ''

@description('Optional. Name of the customer-managed key used for vault encryption.')
param encryptionKeyName string = ''

@description('Optional. Key expiration in days. Also controls auto-rotation: the key is rotated 7 days before expiry.')
@minValue(7)
param keyExpirationInDays int = 180

// ─────────────────────────────────────────────────────────────────────────────

var backupPrivateDnsZoneResourceIds = filter([
  azureBackupPrivateDnsZoneResourceId
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
], z => !empty(z))

// When createVault = false, derive vault coordinates from the provided resource ID.
// These variables MUST be computable from params only (not module outputs) so they can
// be used in module scope expressions which are evaluated at deployment start.
var effectiveVaultSub = createVault ? subscription().subscriptionId : split(existingRecoveryServicesVaultResourceId, '/')[2]
var effectiveVaultRG = createVault ? resourceGroupHosts : split(existingRecoveryServicesVaultResourceId, '/')[4]
var effectiveVaultName = createVault ? vaultName : last(split(existingRecoveryServicesVaultResourceId, '/'))!

var useVaultCmk = createVault && keyManagementType != 'PlatformManaged' && !empty(encryptionKeyVaultResourceId) && !empty(encryptionKeyVaultUri) && !empty(encryptionKeyName)

var encryptionKeyVaultName = !empty(encryptionKeyVaultResourceId) ? last(split(encryptionKeyVaultResourceId, '/'))! : ''
var encryptionKeyVaultSubscriptionId = !empty(encryptionKeyVaultResourceId) ? split(encryptionKeyVaultResourceId, '/')[2] : ''
var encryptionKeyVaultResourceGroup = !empty(encryptionKeyVaultResourceId) ? split(encryptionKeyVaultResourceId, '/')[4] : ''
var kty = contains(keyManagementType, 'HSM') ? 'RSA-HSM' : 'RSA'
var rotationPolicy = {
  attributes: {
    expiryTime: 'P${string(keyExpirationInDays)}D'
  }
  lifetimeActions: [
    {
      action: { type: 'Notify' }
      trigger: { timeBeforeExpiry: 'P10D' }
    }
    {
      action: { type: 'Rotate' }
      trigger: { timeAfterCreate: 'P${string(keyExpirationInDays - 7)}D' }
    }
  ]
}

// ─── Recovery Services Vault ──────────────────────────────────────────────────
//
// Two deployment paths based on identity requirements:
//
//   Path A — CMK (system-assigned identity):
//     The vault always uses its system-assigned identity for CMK. The SAI principal
//     ID is unknown before the vault exists, so the key vault role assignment cannot
//     be pre-created. This requires four sequential steps:
//       A-0  Create the CMK key in Key Vault with rotation policy.
//       A-1  Deploy vault with SystemAssigned identity, NO CMK yet.
//       A-2  Grant the vault SAI 'Key Vault Crypto Service Encryption User' on the CMK key.
//       A-3  Update the vault to enable CMK (ARM handles as an idempotent PUT).
//
//   Path B — platform-managed keys only:
//     Single vault deployment with no CMK configuration.

// ── Path A, Stage A-0: create the CMK key in Key Vault ────────────────────────
module recoveryServicesEncryptionKey '../../../../../.common/bicepModules/keyVault/vaults/keys/deploy.bicep' = if (useVaultCmk) {
  name: 'RSV-CMK-Key-${deploymentSuffix}'
  scope: resourceGroup(encryptionKeyVaultSubscriptionId, encryptionKeyVaultResourceGroup)
  params: {
    keyVaultName: encryptionKeyVaultName
    name: encryptionKeyName
    kty: kty
    keySize: 4096
    attributesEnabled: true
    attributesExportable: false
    rotationPolicy: rotationPolicy
    tags: {}
  }
}

// ── Path A, Stage A-1: establish SAI identity, no CMK yet ─────────────────────
module recoveryServicesVaultInit '../../../../../.common/bicepModules/recoveryServices/vaults/deploy.bicep' = if (createVault && useVaultCmk) {
  name: 'RecoveryServicesVault-Init-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: vaultName
    location: location
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId) ? { workspaceId: logAnalyticsWorkspaceResourceId } : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    storageType: storageRedundancy
    crossRegionRestoreFlag: crossRegionRestoreEnabled
    tags: tags[?'Microsoft.RecoveryServices/vaults'] ?? {}
    cmkKeyUri: ''
    cmkUseSystemAssignedIdentity: true
    cmkUserAssignedIdentityResourceId: ''
  }
}

// ── Path A, Stage A-2: grant vault SAI access to the encryption key ───────────
module recoveryServicesVaultSaiKvRoleAssignment '../../../../../.common/bicepModules/keyVault/vaults/keys/roleAssignment.bicep' = if (createVault && useVaultCmk) {
  name: 'RSV-SAI-KvKeyRA-${deploymentSuffix}'
  scope: resourceGroup(split(encryptionKeyVaultResourceId, '/')[2], split(encryptionKeyVaultResourceId, '/')[4])
  params: {
    keyVaultName: last(split(encryptionKeyVaultResourceId, '/'))!
    keyName: encryptionKeyName
    assignments: [
      {
        roleDefinitionId: 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User
        principalId: recoveryServicesVaultInit!.outputs.principalId
        principalType: 'ServicePrincipal'
        description: 'RSV system-assigned identity — CMK access (SAI always used; Azure also requires SAI when a private endpoint is present).'  
      }
    ]
  }
  dependsOn: [recoveryServicesEncryptionKey]
}

// ── Path A, Stage A-3: enable CMK now that SAI has key access ─────────────────
module recoveryServicesVaultCmk '../../../../../.common/bicepModules/recoveryServices/vaults/deploy.bicep' = if (createVault && useVaultCmk) {
  name: 'RecoveryServicesVault-CMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: vaultName
    location: location
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId) ? { workspaceId: logAnalyticsWorkspaceResourceId } : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    storageType: storageRedundancy
    crossRegionRestoreFlag: crossRegionRestoreEnabled
    tags: tags[?'Microsoft.RecoveryServices/vaults'] ?? {}
    cmkKeyUri: '${encryptionKeyVaultUri}keys/${encryptionKeyName}'
    cmkUseSystemAssignedIdentity: true
    cmkUserAssignedIdentityResourceId: ''
  }
  dependsOn: [recoveryServicesVaultSaiKvRoleAssignment]
}

// ── Path B: platform-managed keys only ───────────────────────────────────────
module recoveryServicesVault '../../../../../.common/bicepModules/recoveryServices/vaults/deploy.bicep' = if (createVault && !useVaultCmk) {
  name: 'RecoveryServicesVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: vaultName
    location: location
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId) ? { workspaceId: logAnalyticsWorkspaceResourceId } : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    storageType: storageRedundancy
    crossRegionRestoreFlag: crossRegionRestoreEnabled
    tags: tags[?'Microsoft.RecoveryServices/vaults'] ?? {}
    cmkKeyUri: ''
    cmkUserAssignedIdentityResourceId: ''
    cmkUseSystemAssignedIdentity: false
  }
}

// ─── VM Backup Policy ────────────────────────────────────────────────────────
module vmBackupPolicy '../../../../../.common/bicepModules/recoveryServices/vaults/backupPolicies/deploy.bicep' = {
  name: 'RSV-BackupPolicy-VirtualMachines-${deploymentSuffix}'
  scope: resourceGroup(effectiveVaultSub, effectiveVaultRG)
  params: {
    recoveryServicesVaultName: effectiveVaultName
    name: vmPolicyName
    properties: {
      backupManagementType: 'AzureIaasVM'
      instantRpRetentionRangeInDays: 2
      policyType: 'V2'
      retentionPolicy: {
        retentionPolicyType: 'LongTermRetentionPolicy'
        dailySchedule: {
          retentionDuration: {
            count: backupRetentionDays
            durationType: 'Days'
          }
          retentionTimes: ['23:00']
        }
      }
      schedulePolicy: {
        schedulePolicyType: 'SimpleSchedulePolicyV2'
        scheduleRunFrequency: 'Daily'
        dailySchedule: {
          scheduleRunTimes: ['23:00']
        }
      }
      timeZone: timeZone
    }
  }
  #disable-next-line no-unnecessary-dependson
  dependsOn: [recoveryServicesVaultCmk, recoveryServicesVault]
}

// ─── Vault Private Endpoint ───────────────────────────────────────────────────
// Only created alongside a new vault (Complete). Existing vaults already have their PE.
module vaultPrivateEndpoint '../../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (createVault && privateEndpoint && !empty(privateEndpointSubnetResourceId) && !empty(azureBackupPrivateDnsZoneResourceId)) {
  name: 'PE-RecoveryServicesVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    name: replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'AzureBackup'), 'RESOURCE', vaultName),
      'VNETID',
      split(privateEndpointSubnetResourceId, '/')[8]
    )
    customNetworkInterfaceName: replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'AzureBackup'), 'RESOURCE', vaultName),
      'VNETID',
      split(privateEndpointSubnetResourceId, '/')[8]
    )
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: useVaultCmk
      ? recoveryServicesVaultCmk!.outputs.resourceId
      : recoveryServicesVault!.outputs.resourceId
    groupId: 'AzureBackup'
    privateDNSZoneIds: backupPrivateDnsZoneResourceIds
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

output recoveryServicesVaultResourceId string = createVault
  ? useVaultCmk
      ? recoveryServicesVaultCmk!.outputs.resourceId
      : recoveryServicesVault!.outputs.resourceId
  : existingRecoveryServicesVaultResourceId

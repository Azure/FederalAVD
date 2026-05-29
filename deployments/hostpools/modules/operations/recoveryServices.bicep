targetScope = 'subscription'

// ─────────────────────────────────────────────────────────────────────────────
// Recovery Services — shared vault in the Operations resource group.
//
// Called from hostpool.bicep BEFORE fslogix and sessionHosts so the vault
// is ready for both phases to register backup items against it.
//
//  • Complete    → createVault = true  (vault + policies + PE created here)
//  • HostPoolOnly → createVault = false (uses existingRecoveryServicesVaultResourceId)
//
// FSLogix Azure Files backup items are registered in fslogix.bicep after
// storage accounts exist. VM backup items are registered in sessionHosts.bicep
// (currently commented out pending ARM/Bicep issue resolution).
// ─────────────────────────────────────────────────────────────────────────────

@description('Required. Whether to create a new Recovery Services Vault. True on Complete deployments; false when using an existing vault.')
param createVault bool

@description('Conditional. Resource ID of an existing Recovery Services Vault. Required when createVault is false.')
param existingRecoveryServicesVaultResourceId string = ''

@description('Required. Name for the Recovery Services Vault (used only when createVault is true).')
param vaultName string

@description('Required. Name of the operations resource group where the vault is (or will be) deployed.')
param resourceGroupOperations string

@description('Required. Azure region for all resources.')
param location string

@description('Required. Storage replication type for a new vault: LocallyRedundant, GeoRedundant, or ZoneRedundant.')
param storageRedundancy string

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

@description('Required. True when the host pool is pooled (file share backup). False when personal (VM backup).')
param pooledHostPool bool
param vmPolicyName string = 'AvdPolicyVm'
param fileSharePolicyName string = 'filesharepolicy'

@description('Optional. Shared key management mode for PaaS resources. When set to CustomerManaged or CustomerManagedHSM and createVault is true, vault CMK is configured.')
@allowed([
  'MicrosoftManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementType string = 'MicrosoftManaged'

@description('Optional. Resource ID of the encryption key vault used for vault CMK configuration.')
param encryptionKeyVaultResourceId string = ''

@description('Optional. URI of the encryption key vault used for vault CMK configuration.')
param encryptionKeyVaultUri string = ''

@description('Optional. Name of the customer-managed key used for vault encryption.')
param encryptionKeyName string = ''

@description('Optional. Name of the user-assigned identity used by the vault to access the CMK.')
param encryptionUserAssignedIdentityName string = ''

@description('Optional. Key expiration in days for newly created CMK keys.')
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
var effectiveVaultRG = createVault ? resourceGroupOperations : split(existingRecoveryServicesVaultResourceId, '/')[4]
var effectiveVaultName = createVault ? vaultName : last(split(existingRecoveryServicesVaultResourceId, '/'))!
var useVaultCmk = createVault && keyManagementType != 'MicrosoftManaged' && !empty(encryptionKeyVaultResourceId) && !empty(encryptionKeyVaultUri) && !empty(encryptionKeyName)
var recoveryServicesCmkIdentityName = !empty(encryptionUserAssignedIdentityName) ? encryptionUserAssignedIdentityName : take('${vaultName}-cmk-uai', 128)

module recoveryServicesCmk '../../../../.common/bicepModules/custom/customerManagedKeys/customerManagedKeys.bicep' = if (useVaultCmk) {
  name: 'RecoveryServices-CMK-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupOperations)
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: keyManagementType == 'CustomerManagedHSM' ? 'CustomerManagedHSM' : 'CustomerManaged'
    keyExpirationInDays: keyExpirationInDays
    location: location
    tags: tags
    deploymentSuffix: deploymentSuffix
    storageKeyNames: [
      encryptionKeyName
    ]
    storageIdentityName: recoveryServicesCmkIdentityName
  }
}

// ─── Recovery Services Vault ──────────────────────────────────────────────────
module recoveryServicesVault '../../../../.common/bicepModules/recoveryServices/vaults/deploy.bicep' = if (createVault) {
  name: 'RecoveryServicesVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupOperations)
  params: {
    name: vaultName
    location: location
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId) ? { workspaceId: logAnalyticsWorkspaceResourceId } : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    storageType: storageRedundancy
    tags: tags[?'Microsoft.RecoveryServices/vaults'] ?? {}
    cmkKeyUri: useVaultCmk ? '${encryptionKeyVaultUri}keys/${encryptionKeyName}' : ''
    cmkUserAssignedIdentityResourceId: useVaultCmk ? recoveryServicesCmk!.outputs.storageIdentityResourceId : ''
  }
}

// ─── VM Backup Policy (personal host pools only) ───────────────────────────
module vmBackupPolicy '../../../../.common/bicepModules/recoveryServices/vaults/backupPolicies/deploy.bicep' = if (!pooledHostPool) {
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
            count: 30
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
  dependsOn: [recoveryServicesVault]
}

// ─── File Share Backup Policy (pooled host pools only) ────────────────────────
module fileShareBackupPolicy '../../../../.common/bicepModules/recoveryServices/vaults/backupPolicies/deploy.bicep' = if (pooledHostPool) {
  name: 'RSV-BackupPolicy-FileShares-${deploymentSuffix}'
  scope: resourceGroup(effectiveVaultSub, effectiveVaultRG)
  params: {
    recoveryServicesVaultName: effectiveVaultName
    name: fileSharePolicyName
    properties: {
      backupManagementType: 'AzureStorage'
      workLoadType: 'AzureFileShare'
      schedulePolicy: {
        schedulePolicyType: 'SimpleSchedulePolicy'
        scheduleRunFrequency: 'Daily'
        scheduleRunTimes: ['23:00']
      }
      retentionPolicy: {
        retentionPolicyType: 'LongTermRetentionPolicy'
        dailySchedule: {
          retentionTimes: ['23:00']
          retentionDuration: {
            count: 30
            durationType: 'Days'
          }
        }
      }
      timeZone: timeZone
    }
  }
  #disable-next-line no-unnecessary-dependson
  dependsOn: [recoveryServicesVault]
}

// ─── Vault Private Endpoint ───────────────────────────────────────────────────
// Only created alongside a new vault (Complete). Existing vaults already have their PE.
module vaultPrivateEndpoint '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (createVault && privateEndpoint && !empty(privateEndpointSubnetResourceId) && !empty(azureBackupPrivateDnsZoneResourceId)) {
  name: 'PE-RecoveryServicesVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupOperations)
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
    privateLinkServiceId: recoveryServicesVault!.outputs.resourceId
    groupId: 'AzureBackup'
    privateDNSZoneIds: backupPrivateDnsZoneResourceIds
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

output recoveryServicesVaultResourceId string = createVault
  ? recoveryServicesVault!.outputs.resourceId
  : existingRecoveryServicesVaultResourceId

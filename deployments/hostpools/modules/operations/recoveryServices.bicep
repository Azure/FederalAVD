targetScope = 'subscription'

// ─────────────────────────────────────────────────────────────────────────────
// Recovery Services — shared Azure Files snapshot-backup vault.
// Deployed in the Operations resource group.
//
// Used for pooled host pool FSLogix Azure Files snapshot backup only.
// No data is transferred to the vault — snapshots remain in the storage account.
// No CMK is required: the vault holds only metadata, not file data; the storage
// account's own encryption protects the actual snapshot data.
// Vault storage replication type is irrelevant for Azure Files snapshot backup
// (data stays in the storage account), so LocallyRedundant is hardcoded.
//
// createVault = false when reusing an existing vault (existingRecoveryServicesVaultResourceId).
// ─────────────────────────────────────────────────────────────────────────────

@description('Required. Whether to create a new Recovery Services Vault.')
param createVault bool

@description('Conditional. Resource ID of an existing Recovery Services Vault. Required when createVault is false.')
param existingRecoveryServicesVaultResourceId string = ''

@description('Required. Name for the Recovery Services Vault (used only when createVault is true).')
param vaultName string

@description('Required. Name of the operations resource group where the vault is (or will be) deployed.')
param resourceGroupOperations string

@description('Required. Azure region for all resources.')
param location string

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

@description('Optional. Name for the Azure Files snapshot backup policy.')
param fileSharePolicyName string = 'filesharepolicy'

@description('Optional. Number of daily snapshots to retain (1–365).')
@minValue(1)
@maxValue(365)
param backupRetentionDays int = 30

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

// ─── Recovery Services Vault ──────────────────────────────────────────────────
// Note: storageType is irrelevant for Azure Files snapshot backup — snapshots stay
// in the storage account. LocallyRedundant is used to minimise cost and complexity.
module recoveryServicesVault '../../../../.common/bicepModules/recoveryServices/vaults/deploy.bicep' = if (createVault) {
  name: 'RecoveryServicesVault-AzureFiles-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupOperations)
  params: {
    name: vaultName
    location: location
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId) ? { workspaceId: logAnalyticsWorkspaceResourceId } : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    storageType: 'LocallyRedundant'
    tags: tags[?'Microsoft.RecoveryServices/vaults'] ?? {}
    cmkKeyUri: ''
    cmkUserAssignedIdentityResourceId: ''
    cmkUseSystemAssignedIdentity: false
  }
}

// ─── Azure Files Snapshot Backup Policy ──────────────────────────────────────
module fileShareBackupPolicy '../../../../.common/bicepModules/recoveryServices/vaults/backupPolicies/deploy.bicep' = {
  name: 'RSV-BackupPolicy-AzureFiles-${deploymentSuffix}'
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
            count: backupRetentionDays
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
  name: 'PE-RecoveryServicesVault-AzureFiles-${deploymentSuffix}'
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

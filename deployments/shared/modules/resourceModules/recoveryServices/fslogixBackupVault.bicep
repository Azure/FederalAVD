targetScope = 'subscription'

@description('Required. Whether to create a new Recovery Services Vault.')
param createVault bool

@description('Required. Whether to create or update the Azure Files snapshot backup policy.')
param manageBackupPolicy bool = true

@description('Conditional. Resource ID of an existing Recovery Services Vault. Required when createVault is false.')
param existingRecoveryServicesVaultResourceId string = ''

@description('Required. Name for the Recovery Services Vault when createVault is true.')
param vaultName string

@description('Required. Name of the operations resource group where the vault is or will be deployed.')
param resourceGroupOperations string

@description('Required. Azure region for all resources.')
param location string

@description('Required. Short unique deployment suffix.')
param deploymentSuffix string

@description('Optional. Resource ID of the Log Analytics workspace for vault diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. Whether to deploy a private endpoint for the vault.')
param privateEndpoint bool

@description('Optional. Resource ID of the subnet for the vault private endpoint.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Resource ID of the Azure Backup private DNS zone.')
param azureBackupPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Blob private DNS zone required by the backup private endpoint.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the Azure Queue private DNS zone required by the backup private endpoint.')
param azureQueuePrivateDnsZoneResourceId string = ''

@description('Required. Name convention for private endpoints.')
param privateEndpointNameConv string

@description('Required. Name convention for private endpoint network interfaces.')
param privateEndpointNICNameConv string

@description('Required. Resource tags object.')
param tags object

@description('Required. Backup policy time zone, such as Eastern Standard Time.')
param timeZone string

@description('Optional. Name for the Azure Files snapshot backup policy.')
param fileSharePolicyName string = 'filesharepolicy'

@description('Optional. Number of daily snapshots to retain.')
@minValue(1)
@maxValue(200)
param backupRetentionDays int = 30

var backupPrivateDnsZoneResourceIds = filter([
  azureBackupPrivateDnsZoneResourceId
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
], zoneResourceId => !empty(zoneResourceId))

var effectiveVaultSubscriptionId = createVault
  ? subscription().subscriptionId
  : split(existingRecoveryServicesVaultResourceId, '/')[2]
var effectiveVaultResourceGroupName = createVault
  ? resourceGroupOperations
  : split(existingRecoveryServicesVaultResourceId, '/')[4]
var effectiveVaultName = createVault
  ? vaultName
  : last(split(existingRecoveryServicesVaultResourceId, '/'))!

// Azure Files snapshots remain in the storage account, so the vault stores backup metadata only.
module recoveryServicesVault 'vaults/deploy.bicep' = if (createVault) {
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

module fileShareBackupPolicy 'vaults/backupPolicies/deploy.bicep' = if (manageBackupPolicy) {
  name: 'RSV-BackupPolicy-AzureFiles-${deploymentSuffix}'
  scope: resourceGroup(effectiveVaultSubscriptionId, effectiveVaultResourceGroupName)
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

module vaultPrivateEndpoint '../network/privateEndpoints/deploy.bicep' = if (createVault && privateEndpoint && !empty(privateEndpointSubnetResourceId) && !empty(azureBackupPrivateDnsZoneResourceId)) {
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

output fileShareBackupPolicyName string = fileSharePolicyName

output fileShareBackupPolicyResourceId string = '/subscriptions/${effectiveVaultSubscriptionId}/resourceGroups/${effectiveVaultResourceGroupName}/providers/Microsoft.RecoveryServices/vaults/${effectiveVaultName}/backupPolicies/${fileSharePolicyName}'

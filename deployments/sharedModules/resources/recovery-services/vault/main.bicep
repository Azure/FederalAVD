@description('Required. Name of the Azure Recovery Service Vault.')
param name string

@description('Optional. The storage configuration for the Azure Recovery Service Vault.')
param backupStorageConfig object = {}

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. List of all backup policies.')
param backupPolicies array = []

@description('Optional. The backup configuration.')
param backupConfig object = {}

@description('Optional. List of all protection containers.')
@minLength(0)
param protectionContainers array = []

@description('Optional. List of all replication fabrics.')
@minLength(0)
param replicationFabrics array = []

@description('Optional. List of all replication policies.')
@minLength(0)
param replicationPolicies array = []

@description('Optional. Replication alert settings.')
param replicationAlertSettings object = {}

@description('Optional. Resource ID of the diagnostic storage account.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource ID of the diagnostic log analytics workspace.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category.')
param diagnosticEventHubName string = ''

@description('Optional. Enables system assigned managed identity on the resource.')
param systemAssignedIdentity bool = false

@description('Optional. The ID(s) to assign to the resource.')
param userAssignedIdentities object = {}

@description('Optional. Tags of the Recovery Service Vault resource.')
param tags object = {}

@description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource. Set to \'\' to disable log collection.')
@allowed([
  ''
  'allLogs'
  'AzureBackupReport'
  'CoreAzureBackup'
  'AddonAzureBackupJobs'
  'AddonAzureBackupAlerts'
  'AddonAzureBackupPolicy'
  'AddonAzureBackupStorage'
  'AddonAzureBackupProtectedInstance'
  'AzureSiteRecoveryJobs'
  'AzureSiteRecoveryEvents'
  'AzureSiteRecoveryReplicatedItems'
  'AzureSiteRecoveryReplicationStats'
  'AzureSiteRecoveryRecoveryPoints'
  'AzureSiteRecoveryReplicationDataUploadRate'
  'AzureSiteRecoveryProtectedDiskDataChurn'
])
param diagnosticLogCategoriesToEnable array = [
  'allLogs'
]

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'AllMetrics'
])
param diagnosticMetricsToEnable array = [
  'AllMetrics'
]

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

@description('Optional. Configuration details for private endpoints. For security reasons, it is recommended to use private endpoints whenever possible.')
param privateEndpoints array = []

@description('Optional. Monitoring Settings of the vault.')
param monitoringSettings object = {}

@description('Optional. Security Settings of the vault.')
param securitySettings object = {}

@description('Optional. Whether or not public network access is allowed for this resource. For security reasons it should be disabled.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

var diagnosticsLogsSpecified = [for category in filter(diagnosticLogCategoriesToEnable, item => item != 'allLogs' && item != ''): {
  category: category
  enabled: true
}]

var diagnosticsLogs = contains(diagnosticLogCategoriesToEnable, 'allLogs') ? [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
] : contains(diagnosticLogCategoriesToEnable, '') ? [] : diagnosticsLogsSpecified

var diagnosticsMetrics = [for metric in diagnosticMetricsToEnable: {
  category: metric
  timeGrain: null
  enabled: true
}]

var identityType = systemAssignedIdentity ? (!empty(userAssignedIdentities) ? 'SystemAssigned,UserAssigned' : 'SystemAssigned') : (!empty(userAssignedIdentities) ? 'UserAssigned' : 'None')

var identity = identityType != 'None' ? {
  type: identityType
  userAssignedIdentities: !empty(userAssignedIdentities) ? userAssignedIdentities : null
} : null

resource rsv 'Microsoft.RecoveryServices/vaults@2023-01-01' = {
  name: name
  location: location
  tags: tags
  identity: identity
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    monitoringSettings: !empty(monitoringSettings) ? monitoringSettings : null
    securitySettings: !empty(securitySettings) ? securitySettings : null
    publicNetworkAccess: publicNetworkAccess
  }
}

module rsv_replicationFabrics 'replication-fabric/main.bicep' = [for (replicationFabric, index) in replicationFabrics: {
  name: '${uniqueString(deployment().name, location)}-RSV-Fabric-${index}'
  params: {
    recoveryVaultName: rsv.name
    name: replicationFabric.?name ?? replicationFabric.location
    location: replicationFabric.location
    replicationContainers: replicationFabric.?replicationContainers ?? []
  }
  dependsOn: [
    rsv_replicationPolicies
  ]
}]

module rsv_replicationPolicies 'replication-policy/main.bicep' = [for (replicationPolicy, index) in replicationPolicies: {
  name: '${uniqueString(deployment().name, location)}-RSV-Policy-${index}'
  params: {
    name: replicationPolicy.name
    recoveryVaultName: rsv.name
    appConsistentFrequencyInMinutes: replicationPolicy.?appConsistentFrequencyInMinutes ?? 60
    crashConsistentFrequencyInMinutes: replicationPolicy.?crashConsistentFrequencyInMinutes ?? 5
    multiVmSyncStatus: replicationPolicy.?multiVmSyncStatus ?? 'Enable'
    recoveryPointHistory: replicationPolicy.?recoveryPointHistory ?? 1440
  }
}]

module rsv_backupStorageConfiguration 'backup-storage-config/main.bicep' = if (!empty(backupStorageConfig)) {
  name: '${uniqueString(deployment().name, location)}-RSV-BackupStorageConfig'
  params: {
    recoveryVaultName: rsv.name
    storageModelType: backupStorageConfig.storageModelType
    crossRegionRestoreFlag: backupStorageConfig.crossRegionRestoreFlag
  }
}

module rsv_backupFabric_protectionContainers 'backup-fabric/protection-container/main.bicep' = [for (protectionContainer, index) in protectionContainers: {
  name: '${uniqueString(deployment().name, location)}-RSV-ProtectionContainers-${index}'
  params: {
    recoveryVaultName: rsv.name
    name: protectionContainer.name
    sourceResourceId: protectionContainer.sourceResourceId
    friendlyName: protectionContainer.friendlyName
    backupManagementType: protectionContainer.backupManagementType
    containerType: protectionContainer.containerType
    protectedItems: protectionContainer.?protectedItems ?? []
    location: location
  }
}]

module rsv_backupPolicies 'backup-policy/main.bicep' = [for (backupPolicy, index) in backupPolicies: {
  name: '${uniqueString(deployment().name, location)}-RSV-BackupPolicy-${index}'
  params: {
    recoveryVaultName: rsv.name
    name: backupPolicy.name
    properties: backupPolicy.properties
  }
}]

module rsv_backupConfig 'backup-config/main.bicep' = if (!empty(backupConfig)) {
  name: '${uniqueString(deployment().name, location)}-RSV-BackupConfig'
  params: {
    recoveryVaultName: rsv.name
    name: backupConfig.?name ?? 'vaultconfig'
    enhancedSecurityState: backupConfig.?enhancedSecurityState ?? 'Enabled'
    resourceGuardOperationRequests: backupConfig.?resourceGuardOperationRequests ?? []
    softDeleteFeatureState: backupConfig.?softDeleteFeatureState ?? 'Enabled'
    storageModelType: backupConfig.?storageModelType ?? 'GeoRedundant'
    storageType: backupConfig.?storageType ?? 'GeoRedundant'
    storageTypeState: backupConfig.?storageTypeState ?? 'Locked'
    isSoftDeleteFeatureStateEditable: backupConfig.?isSoftDeleteFeatureStateEditable ?? true
  }
}

module rsv_replicationAlertSettings 'replication-alert-setting/main.bicep' = if (!empty(replicationAlertSettings)) {
  name: 'RSV-replicationAlertSettings-${uniqueString(deployment().name, location)}'
  params: {
    name: 'defaultAlertSetting'
    recoveryVaultName: rsv.name
    customEmailAddresses: replicationAlertSettings.?customEmailAddresses ?? []
    locale: replicationAlertSettings.?locale ?? ''
    sendToOwners: replicationAlertSettings.?sendToOwners ?? 'Send'
  }
}

resource rsv_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if ((!empty(diagnosticStorageAccountId)) || (!empty(diagnosticWorkspaceId)) || (!empty(diagnosticEventHubAuthorizationRuleId)) || (!empty(diagnosticEventHubName))) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {
    storageAccountId: !empty(diagnosticStorageAccountId) ? diagnosticStorageAccountId : null
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    eventHubAuthorizationRuleId: !empty(diagnosticEventHubAuthorizationRuleId) ? diagnosticEventHubAuthorizationRuleId : null
    eventHubName: !empty(diagnosticEventHubName) ? diagnosticEventHubName : null
    metrics: environment().name == 'AzureCloud' ? diagnosticsMetrics : null
    logs: diagnosticsLogs
  }
  scope: rsv
}

module rsv_privateEndpoints '../../network/private-endpoint/main.bicep' = [for (privateEndpoint, index) in privateEndpoints: {
  name: 'RSV-PrivateEndpoint-${index}-${uniqueString(deployment().name, location)}'
  params: {
    groupIds: [
      privateEndpoint.service
    ]
    name: privateEndpoint.?name ?? 'pe-${last(split(rsv.id, '/'))}-${privateEndpoint.service}-${index}'
    serviceResourceId: rsv.id
    subnetResourceId: privateEndpoint.subnetResourceId
    location: privateEndpoint.?location ?? reference(split(privateEndpoint.subnetResourceId, '/subnets/')[0], '2020-06-01', 'Full').location
    privateDnsZoneGroup: privateEndpoint.?privateDnsZoneGroup ?? {}
    tags: privateEndpoint.?tags ?? {}
    manualPrivateLinkServiceConnections: privateEndpoint.?manualPrivateLinkServiceConnections ?? []
    customDnsConfigs: privateEndpoint.?customDnsConfigs ?? []
    ipConfigurations: privateEndpoint.?ipConfigurations ?? []
    applicationSecurityGroups: privateEndpoint.?applicationSecurityGroups ?? []
    customNetworkInterfaceName: privateEndpoint.?customNetworkInterfaceName ?? ''
  }
}]

@description('The resource ID of the recovery services vault.')
output resourceId string = rsv.id

@description('The name of the resource group the recovery services vault was created in.')
output resourceGroupName string = resourceGroup().name

@description('The Name of the recovery services vault.')
output name string = rsv.name

@description('The principal ID of the system assigned identity.')
output systemAssignedPrincipalId string = systemAssignedIdentity && contains(rsv.identity, 'principalId') ? rsv.identity.principalId : ''

@description('The location the resource was deployed into.')
output location string = rsv.location

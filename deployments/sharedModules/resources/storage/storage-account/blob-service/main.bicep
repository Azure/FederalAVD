@maxLength(24)
@description('Conditional. The name of the parent Storage Account. Required if the template is used in a standalone deployment.')
param storageAccountName string

@description('Optional. Automatic Snapshot is enabled if set to true.')
param automaticSnapshotPolicyEnabled bool = false

@description('Optional. The blob service properties for change feed events. Indicates whether change feed event logging is enabled for the Blob service.')
param changeFeedEnabled bool = true

@minValue(1)
@maxValue(146000)
@description('Optional. Indicates whether change feed event logging is enabled for the Blob service. Indicates the duration of changeFeed retention in days. A "0" value indicates an infinite retention of the change feed.')
param changeFeedRetentionInDays int?

@description('Optional. The blob service properties for container soft delete. Indicates whether DeleteRetentionPolicy is enabled.')
param containerDeleteRetentionPolicyEnabled bool = true

@minValue(1)
@maxValue(365)
@description('Optional. Indicates the number of days that the deleted item should be retained.')
param containerDeleteRetentionPolicyDays int = 7

@description('Optional. This property when set to true allows deletion of the soft deleted blob versions and snapshots. This property cannot be used with blob restore policy. This property only applies to blob service and does not apply to containers or file share.')
param containerDeleteRetentionPolicyAllowPermanentDelete bool = false

@description('Optional. Specifies CORS rules for the Blob service. You can include up to five CorsRule elements in the request. If no CorsRule elements are included in the request body, all CORS rules will be deleted, and CORS will be disabled for the Blob service.')
param corsRules array = []

@description('Optional. Indicates the default version to use for requests to the Blob service if an incoming request\'s version is not specified. Possible values include version 2008-10-27 and all more recent versions.')
param defaultServiceVersion string = ''

@description('Optional. The blob service properties for blob soft delete.')
param deleteRetentionPolicyEnabled bool = true

@minValue(1)
@maxValue(365)
@description('Optional. Indicates the number of days that the deleted blob should be retained.')
param deleteRetentionPolicyDays int = 7

@description('Optional. This property when set to true allows deletion of the soft deleted blob versions and snapshots. This property cannot be used with blob restore policy. This property only applies to blob service and does not apply to containers or file share.')
param deleteRetentionPolicyAllowPermanentDelete bool = false

@description('Optional. Use versioning to automatically maintain previous versions of your blobs.')
param isVersioningEnabled bool = true

@description('Optional. The blob service property to configure last access time based tracking policy. When set to true last access time based tracking is enabled.')
param lastAccessTimeTrackingPolicyEnabled bool = false

@description('Optional. The blob service properties for blob restore policy. If point-in-time restore is enabled, then versioning, change feed, and blob soft delete must also be enabled.')
param restorePolicyEnabled bool = true

@minValue(1)
@description('Optional. how long this blob can be restored. It should be less than DeleteRetentionPolicy days.')
param restorePolicyDays int = 6

@description('Optional. Blob containers to create.')
param containers array = []

@description('Optional. Resource ID of the diagnostic storage account.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource ID of a log analytics workspace.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category.')
param diagnosticEventHubName string = ''

@description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource. Set to \'\' to disable log collection.')
@allowed([
  ''
  'allLogs'
  'StorageRead'
  'StorageWrite'
  'StorageDelete'
])
param diagnosticLogCategoriesToEnable array = [
  'allLogs'
]

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'Transaction'
])
param diagnosticMetricsToEnable array = [
  'Transaction'
]

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

// The name of the blob services
var name = 'default'

var diagnosticsLogsSpecified = [
  for category in filter(diagnosticLogCategoriesToEnable, item => item != 'allLogs' && item != ''): {
    category: category
    enabled: true
  }
]

var diagnosticsLogs = contains(diagnosticLogCategoriesToEnable, 'allLogs')
  ? [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  : contains(diagnosticLogCategoriesToEnable, '') ? [] : diagnosticsLogsSpecified

var diagnosticsMetrics = [
  for metric in diagnosticMetricsToEnable: {
    category: metric
    timeGrain: null
    enabled: true
  }
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  name: name
  parent: storageAccount
  properties: {
    automaticSnapshotPolicyEnabled: automaticSnapshotPolicyEnabled
    changeFeed: changeFeedEnabled
      ? {
          enabled: true
          retentionInDays: changeFeedRetentionInDays
        }
      : null
    containerDeleteRetentionPolicy: {
      enabled: containerDeleteRetentionPolicyEnabled
      days: containerDeleteRetentionPolicyEnabled == true ? containerDeleteRetentionPolicyDays : null
      allowPermanentDelete: containerDeleteRetentionPolicyEnabled == true
        ? containerDeleteRetentionPolicyAllowPermanentDelete
        : null
    }
    cors: {
      corsRules: corsRules
    }
    defaultServiceVersion: !empty(defaultServiceVersion) ? defaultServiceVersion : null
    deleteRetentionPolicy: {
      enabled: deleteRetentionPolicyEnabled
      days: deleteRetentionPolicyEnabled == true ? deleteRetentionPolicyDays : null
      allowPermanentDelete: deleteRetentionPolicyEnabled && deleteRetentionPolicyAllowPermanentDelete ? true : null
    }
    isVersioningEnabled: isVersioningEnabled
    lastAccessTimeTrackingPolicy: {
      enable: lastAccessTimeTrackingPolicyEnabled
      name: lastAccessTimeTrackingPolicyEnabled == true ? 'AccessTimeTracking' : null
      trackingGranularityInDays: lastAccessTimeTrackingPolicyEnabled == true ? 1 : null
    }
    restorePolicy: {
      enabled: restorePolicyEnabled
      days: restorePolicyEnabled == true ? restorePolicyDays : null
    }
  }
}

resource blobServices_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if ((!empty(diagnosticStorageAccountId)) || (!empty(diagnosticWorkspaceId)) || (!empty(diagnosticEventHubAuthorizationRuleId)) || (!empty(diagnosticEventHubName))) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {
    storageAccountId: !empty(diagnosticStorageAccountId) ? diagnosticStorageAccountId : null
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    eventHubAuthorizationRuleId: !empty(diagnosticEventHubAuthorizationRuleId)
      ? diagnosticEventHubAuthorizationRuleId
      : null
    eventHubName: !empty(diagnosticEventHubName) ? diagnosticEventHubName : null
    metrics: diagnosticsMetrics
    logs: diagnosticsLogs
  }
  scope: blobServices
}

module blobServices_container 'container/main.bicep' = [
  for (container, index) in containers: {
    name: 'Container-${index}-${deployment().name}'
    params: {
      storageAccountName: storageAccount.name
      name: container.name
      defaultEncryptionScope: container.?defaultEncryptionScope ?? ''
      denyEncryptionScopeOverride: container.?denyEncryptionScopeOverride ?? false
      enableNfsV3AllSquash: container.?enableNfsV3AllSquash ?? false
      enableNfsV3RootSquash: container.?enableNfsV3RootSquash ?? false
      immutableStorageWithVersioningEnabled: container.?immutableStorageWithVersioningEnabled ?? false
      metadata: container.?metadata ?? {}
      publicAccess: container.?publicAccess ?? 'None'
      immutabilityPolicyProperties: container.?immutabilityPolicyProperties ?? {}
    }
  }
]

@description('The name of the deployed blob service.')
output name string = blobServices.name

@description('The resource ID of the deployed blob service.')
output resourceId string = blobServices.id

@description('The name of the deployed blob service.')
output resourceGroupName string = resourceGroup().name

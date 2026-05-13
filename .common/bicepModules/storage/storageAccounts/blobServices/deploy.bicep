import { diagnosticSettingsType } from '../../../types/diagnosticSettings.bicep'

param storageAccountName string

param deleteRetentionPolicyEnabled bool = false
param deleteRetentionPolicyDays int = 7

param containerDeleteRetentionPolicyEnabled bool = false
param containerDeleteRetentionPolicyDays int = 7

param versioningEnabled bool = false
param changeFeedEnabled bool = false

param diagnosticSettings diagnosticSettingsType?

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: deleteRetentionPolicyEnabled
      days: deleteRetentionPolicyEnabled ? deleteRetentionPolicyDays : null
    }
    containerDeleteRetentionPolicy: {
      enabled: containerDeleteRetentionPolicyEnabled
      days: containerDeleteRetentionPolicyEnabled ? containerDeleteRetentionPolicyDays : null
    }
    isVersioningEnabled: versioningEnabled
    changeFeed: {
      enabled: changeFeedEnabled
    }
  }
}

var diagTargetNames = filter([
  !empty(diagnosticSettings.?workspaceId ?? '') ? last(split(diagnosticSettings.?workspaceId!, '/')) : ''
  !empty(diagnosticSettings.?storageAccountId ?? '') ? last(split(diagnosticSettings.?storageAccountId!, '/')) : ''
  !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? '')
    ? (!empty(diagnosticSettings.?eventHubName ?? '') ? diagnosticSettings!.eventHubName! : split(diagnosticSettings.?eventHubAuthorizationRuleId!, '/')[8])
    : ''
], t => !empty(t))

var diagnosticSettingName = !empty(diagnosticSettings.?name ?? '')
  ? diagnosticSettings!.name!
  : length(diagTargetNames) > 1
      ? 'diag-${uniqueString(join(diagTargetNames, '-'))}'
      : length(diagTargetNames) == 1
          ? 'diag-${diagTargetNames[0]}'
          : 'diagnostics'

resource diagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettings != null && (!empty(diagnosticSettings.?workspaceId ?? '') || !empty(diagnosticSettings.?storageAccountId ?? '') || !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? ''))) {
  scope: blobService
  name: diagnosticSettingName
  properties: {
    workspaceId: diagnosticSettings.?workspaceId
    storageAccountId: diagnosticSettings.?storageAccountId
    eventHubAuthorizationRuleId: diagnosticSettings.?eventHubAuthorizationRuleId
    eventHubName: diagnosticSettings.?eventHubName
    logs: diagnosticSettings.?logCategories ?? [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

output resourceId string = blobService.id
output name string = blobService.name

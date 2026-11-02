metadata name = 'Blob service settings'
metadata description = 'Configures the default Blob service on an existing storage account, including soft delete, versioning, change feed and optional diagnostics. Containers are managed separately.'

import { diagnosticSettingsType } from '../../../types/diagnosticSettings.bicep'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string

@description('Optional. Enable soft delete for blobs in this storage account.')
param deleteRetentionPolicyEnabled bool = false
@description('Optional. Days to retain deleted blobs; applied only when blob soft delete is enabled.')
param deleteRetentionPolicyDays int = 7

@description('Optional. Enable soft delete for Blob containers in this storage account.')
param containerDeleteRetentionPolicyEnabled bool = false
@description('Optional. Days to retain deleted containers; applied only when container soft delete is enabled.')
param containerDeleteRetentionPolicyDays int = 7

@description('Optional. Enable Blob versioning on the default Blob service.')
param versioningEnabled bool = false
@description('Optional. Enable the Blob change feed on the default Blob service.')
param changeFeedEnabled bool = false

// Referenced diagnostic destination resources must already exist.
@description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
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

@description('Resource ID of the blob service settings.')
output resourceId string = blobService.id
@description('Azure resource name of the blob service settings.')
output name string = blobService.name

metadata name = 'Azure Files service settings'
metadata description = 'Configures the default File service on an existing storage account with optional SMB settings, share soft delete and diagnostics. File shares and identity authentication are managed separately.'

import { diagnosticSettingsType } from '../../../types/diagnosticSettings.bicep'
import { smbSettingsType } from '../../../types/storageTypes.bicep'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string

@description('Optional. SMB protocol settings.')
param smbSettings smbSettingsType?

@description('Optional. Enable soft delete for Azure file shares in this storage account.')
param shareDeleteRetentionPolicyEnabled bool = false

@description('Optional. Number of days to retain deleted file shares (1–365). Only effective when shareDeleteRetentionPolicyEnabled is true.')
@minValue(1)
@maxValue(365)
param shareDeleteRetentionPolicyDays int = 14

// Referenced diagnostic destination resources must already exist.
@description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
param diagnosticSettings diagnosticSettingsType?

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    protocolSettings: smbSettings != null
      ? {
          smb: smbSettings
        }
      : null
    shareDeleteRetentionPolicy: {
      enabled: shareDeleteRetentionPolicyEnabled
      days: shareDeleteRetentionPolicyDays
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
  scope: fileService
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

@description('Resource ID of the azure Files service settings.')
output resourceId string = fileService.id
@description('Azure resource name of the azure Files service settings.')
output name string = fileService.name

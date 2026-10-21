metadata name = 'Log Analytics workspace'
metadata description = 'Deploys a Log Analytics workspace with caller-selected pricing, retention and optional diagnostics; data collection rules and resource diagnostic sources are configured separately.'

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@description('Required. Name of the log Analytics workspace to deploy.')
param name string
@description('Optional. Azure region for the log Analytics workspace; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the log Analytics workspace.')
param tags object = {}

@allowed(['PerGB2018', 'CapacityReservation', 'Free', 'LACluster', 'PerNode', 'Premium', 'Standalone', 'Standard'])
@description('Optional. Log Analytics workspace pricing SKU.')
param sku string = 'PerGB2018'

@description('Data retention in days (30–730).')
param retentionInDays int = 30

// Referenced diagnostic destination resources must already exist.
@description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
param diagnosticSettings diagnosticSettingsType?

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { name: sku }
    retentionInDays: retentionInDays
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
  scope: logAnalyticsWorkspace
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
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

@description('Resource ID of the log Analytics workspace.')
output resourceId string = logAnalyticsWorkspace.id
@description('Azure resource name of the log Analytics workspace.')
output name string = logAnalyticsWorkspace.name

// AVD Alerts Add-On - Storage Alert Rules Module
// Deploys metric-based and log-based alert rules for an Azure Files storage account
// used for FSLogix profile storage.
//
// Metric alerts (per storage account) -- latency uses dynamic (learned) thresholds:
//   - SuccessServerLatency above learned baseline, medium sensitivity (Sev 2)
//   - SuccessServerLatency above learned baseline, low sensitivity    (Sev 1)
//   - SuccessE2ELatency    above learned baseline, medium sensitivity (Sev 2)
//   - SuccessE2ELatency    above learned baseline, low sensitivity    (Sev 1)
//   - Availability < 99%                                              (Sev 1)
//
// NOTE: Latency alerts use dynamic thresholds so they adapt to peak/non-peak
//       patterns and suppress false positives during idle periods. Azure Monitor
//       requires ~3 days of metric history before the learned baseline fires.
//
// File share metric alerts (per file service):
//   - Throttling (Transactions with throttling response types)  (Sev 2)
//
// Log-based alerts (storage space - require Automation Account runbook data):
//   - Azure Files share <= 15% remaining  (Sev 2)
//   - Azure Files share <=  5% remaining  (Sev 1)
//
// NOTE: The log-based storage space alerts are created once per deployment (not per
//       storage account) because the runbook outputs all shares to a single job stream.
//       Pass createStorageLogAlerts = true only on the first storage account in the array.

// ========== //
// Parameters //
// ========== //

@description('Required. Resource ID of the storage account to monitor.')
param storageAccountResourceId string

@description('Required. Resource ID of the Action Group for notifications.')
param actionGroupResourceId string

@description('Optional. Prefix prepended to all alert names.')
param alertNamePrefix string = 'AVD'

@description('Optional. Whether alert rules auto-resolve when the condition clears.')
param autoResolveAlert bool = true

@description('Optional. Azure region for the alert rule resources.')
param location string

@description('Optional. Log Analytics Workspace resource ID. Required when createStorageLogAlerts is true.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Set true to also create the log-based storage space alerts (driven by the AA runbook). Only set true for one storage account per deployment to avoid duplicate alert rules.')
param createStorageLogAlerts bool = false

@description('Optional. When false, storage server and end-to-end latency alert rules are not deployed.')
param enableStorageLatencyAlerts bool = true

@description('Optional. When false, storage account availability alert rules are not deployed.')
param enableStorageAvailabilityAlerts bool = true

@description('Optional. When false, file share throttling alert rules are not deployed.')
param enableStorageThrottlingAlerts bool = true

// ========== //
// Variables  //
// ========== //

var storageAccountName  = last(split(storageAccountResourceId, '/'))
var fileServiceResourceId = '${storageAccountResourceId}/fileServices/default'
var descriptionHeader   = 'AVD - Automated Alert\n'

var metricActions = [
  {
    actionGroupId: actionGroupResourceId
  }
]

// ========== //
// Resources  //
// ========== //

// SuccessServerLatency above learned baseline - medium sensitivity (Sev 2)
resource alertServerLatency50 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableStorageLatencyAlerts) {
  name: '${alertNamePrefix}-AzFiles-Latency-ServerWarn-${storageAccountName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Storage account server latency exceeded its dynamically learned baseline. This may indicate performance degradation for FSLogix user profiles. Storage account: ${storageAccountName}.'
    severity: 2
    enabled: true
    scopes: [storageAccountResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.Storage/storageAccounts'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        #disable-next-line BCP035
        {
          name: 'Metric1'
          metricName: 'SuccessServerLatency'
          operator: 'GreaterThan'
          timeAggregation: 'Average'
          criterionType: 'DynamicThresholdCriterion'
          alertSensitivity: 'Medium'
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 3
          }
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// SuccessServerLatency significantly above learned baseline - low sensitivity (Sev 1)
resource alertServerLatency100 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableStorageLatencyAlerts) {
  name: '${alertNamePrefix}-AzFiles-Latency-ServerCrit-${storageAccountName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Storage account server latency significantly exceeded its dynamically learned baseline. Users may be experiencing slow profile loading or degraded application performance. Storage account: ${storageAccountName}.'
    severity: 1
    enabled: true
    scopes: [storageAccountResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.Storage/storageAccounts'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        #disable-next-line BCP035
        {
          name: 'Metric1'
          metricName: 'SuccessServerLatency'
          operator: 'GreaterThan'
          timeAggregation: 'Average'
          criterionType: 'DynamicThresholdCriterion'
          alertSensitivity: 'Low'
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 4
          }
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// SuccessE2ELatency above learned baseline - medium sensitivity (Sev 2)
resource alertE2ELatency50 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableStorageLatencyAlerts) {
  name: '${alertNamePrefix}-AzFiles-Latency-E2EWarn-${storageAccountName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}End-to-end latency from session host to storage exceeded its dynamically learned baseline. This includes network latency and may indicate network path or performance issues. Storage account: ${storageAccountName}.'
    severity: 2
    enabled: true
    scopes: [storageAccountResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.Storage/storageAccounts'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        #disable-next-line BCP035
        {
          name: 'Metric1'
          metricName: 'SuccessE2ELatency'
          operator: 'GreaterThan'
          timeAggregation: 'Average'
          criterionType: 'DynamicThresholdCriterion'
          alertSensitivity: 'Medium'
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 3
          }
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// SuccessE2ELatency significantly above learned baseline - low sensitivity (Sev 1)
resource alertE2ELatency100 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableStorageLatencyAlerts) {
  name: '${alertNamePrefix}-AzFiles-Latency-E2ECrit-${storageAccountName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}End-to-end latency from session host to storage significantly exceeded its dynamically learned baseline. Users are likely experiencing degraded profile performance. Storage account: ${storageAccountName}.'
    severity: 1
    enabled: true
    scopes: [storageAccountResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.Storage/storageAccounts'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        #disable-next-line BCP035
        {
          name: 'Metric1'
          metricName: 'SuccessE2ELatency'
          operator: 'GreaterThan'
          timeAggregation: 'Average'
          criterionType: 'DynamicThresholdCriterion'
          alertSensitivity: 'Low'
          failingPeriods: {
            numberOfEvaluationPeriods: 4
            minFailingPeriodsToAlert: 4
          }
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// Availability < 99% (Sev 1)
resource alertAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableStorageAvailabilityAlerts) {
  name: '${alertNamePrefix}-AzFiles-Avail-Below99pct-${storageAccountName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Storage account availability dropped below 99%. FSLogix user profiles and MSIX App Attach may be unavailable. Storage account: ${storageAccountName}.'
    severity: 1
    enabled: true
    scopes: [storageAccountResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Storage/storageAccounts'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricName: 'Availability'
          operator: 'LessThan'
          threshold: 99
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// File share throttling - IOPS limit reached (Sev 2)
resource alertFileShareThrottling 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableStorageThrottlingAlerts) {
  name: '${alertNamePrefix}-AzFiles-Throttled-${storageAccountName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Azure Files share is being throttled due to high IOPS. Users may experience slow profile operations. Consider upgrading to a higher tier or increasing the provisioned capacity. Storage account: ${storageAccountName}.'
    severity: 2
    enabled: true
    scopes: [fileServiceResourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.Storage/storageAccounts/fileServices'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricName: 'Transactions'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'ResponseType'
              operator: 'Include'
              values: [
                'SuccessWithThrottling'
                'SuccessWithShareEgressThrottling'
                'SuccessWithShareIngressThrottling'
                'SuccessWithShareIopsThrottling'
                'ClientShareEgressThrottlingError'
                'ClientShareIngressThrottlingError'
                'ClientShareIopsThrottlingError'
              ]
            }
          ]
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// ------------------------------------
// Log-based storage space alerts
// Driven by AvdStorageLogData runbook output -> Log Analytics
// Only create when createStorageLogAlerts is true
// ------------------------------------

// Azure Files share <= 15% free space (Sev 2)
resource alertStorageLowSpace15 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (createStorageLogAlerts) {
  name: '${alertNamePrefix}-AzFiles-Space-Low15pct'
  location: location
  properties: {
    displayName: '${alertNamePrefix} - Azure Files Share Low Space - 15% Remaining'
    description: '${descriptionHeader}An Azure Files share used for FSLogix profiles has 15% or less free space. Review share quota and used space, and increase quota to avoid profile load failures.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT10M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdStorageLogData"
| where split(ResultDescription, ',')[1] != ""
| extend StorageAccount=tostring(split(ResultDescription, ',')[1])
| extend ResourceGroup=tostring(split(ResultDescription, ',')[2])
| extend Share=tostring(split(ResultDescription, ',')[3])
| extend GBShareQuota=split(ResultDescription, ',')[4]
| extend GBUsed=split(ResultDescription, ',')[5]
| extend PercentAvailable=round(toreal(split(ResultDescription, ',')[6]))
| extend ResourceId=tostring(split(ResultDescription, ',')[7])
| summarize arg_max(TimeGenerated, *) by Share
| where PercentAvailable <= 15.00
| project TimeGenerated, ResourceId, StorageAccount, Share, PercentAvailable
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'StorageAccount', operator: 'Include', values: ['*'] }
            { name: 'Share', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroupResourceId]
    }
  }
}

// Azure Files share <= 5% free space (Sev 1)
resource alertStorageLowSpace5 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (createStorageLogAlerts) {
  name: '${alertNamePrefix}-AzFiles-Space-Low5pct'
  location: location
  properties: {
    displayName: '${alertNamePrefix} - Azure Files Share Low Space - 5% Remaining'
    description: '${descriptionHeader}CRITICAL: An Azure Files share used for FSLogix profiles has 5% or less free space. New profile loads will fail when the share fills up. Increase quota immediately.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT10M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdStorageLogData"
| where split(ResultDescription, ',')[1] != ""
| extend StorageAccount=tostring(split(ResultDescription, ',')[1])
| extend ResourceGroup=tostring(split(ResultDescription, ',')[2])
| extend Share=tostring(split(ResultDescription, ',')[3])
| extend GBShareQuota=split(ResultDescription, ',')[4]
| extend GBUsed=split(ResultDescription, ',')[5]
| extend PercentAvailable=round(toreal(split(ResultDescription, ',')[6]))
| extend ResourceId=tostring(split(ResultDescription, ',')[7])
| summarize arg_max(TimeGenerated, *) by Share
| where PercentAvailable <= 5.00
| project TimeGenerated, ResourceId, StorageAccount, Share, PercentAvailable
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'StorageAccount', operator: 'Include', values: ['*'] }
            { name: 'Share', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroupResourceId]
    }
  }
}

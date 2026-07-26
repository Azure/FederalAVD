// =============================================
// SessionHostReplacer Alert Rules
// =============================================
// This module creates monitoring alerts for SessionHostReplacer function
// Deploy alongside the main SessionHostReplacer deployment

@description('Name of the Function App to monitor')
param functionAppName string

@description('Resource ID of Application Insights instance')
param applicationInsightsResourceId string

@description('Resource ID of the Action Group for alert notifications')
param actionGroupResourceId string

@description('Location for alert rules')
param location string = resourceGroup().location

@description('Alert severity levels to deploy. Options: Critical, High, Medium, All')
@allowed([
  'Critical'
  'High'
  'Medium'
  'All'
])
param alertLevel string = 'Critical'

@description('Enable or disable all alerts')
param enableAlerts bool = true

@description('Tags to apply to alert resources')
param tags object = {}

// Define all alert configurations
var allAlerts = [
  // ==================== CRITICAL ALERTS (Severity 0-1) ====================
  {
    name: 'shr-${functionAppName}-deployment-failure-pending-hosts'
    displayName: 'SessionHostReplacer - Deployment Failure with Pending Hosts'
    description: 'Deployment failed and hosts are deleted but not replaced (DeleteFirst mode). CRITICAL: Capacity loss.'
    severity: 0
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where message has "Deployment failed" and message has "pending host mappings"
| summarize FailureCount = count(), LastFailure = max(timestamp), sample_message = any(message)
| where FailureCount > 0
'''
    threshold: 1
    frequency: 'PT5M'
    timeWindow: 'PT15M'
    enabled: true
  }
  {
    name: 'shr-${functionAppName}-device-cleanup-blocking'
    displayName: 'SessionHostReplacer - Device Cleanup Failure Blocking Deployment'
    description: 'DeleteFirst mode blocked because Entra/Intune cleanup failed. Check Graph API permissions.'
    severity: 0
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(30m)
| where message has "Device cleanup verification failed" or message has "cannot safely reuse hostnames"
| summarize FailureCount = count(), LastFailure = max(timestamp), sample_message = any(message)
| where FailureCount > 0
'''
    threshold: 1
    frequency: 'PT5M'
    timeWindow: 'PT30M'
    enabled: true
  }
  {
    name: 'shr-${functionAppName}-safety-check-low-capacity'
    displayName: 'SessionHostReplacer - Safety Check Failed with Low Capacity'
    description: 'SideBySide mode: New hosts not Available and pool capacity below 80%'
    severity: 1
    query: '''
let safety_failures = traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where message has "SAFETY CHECK FAILED"
| project timestamp;
let capacity_checks = traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where message has "Current available capacity" and message has "%"
| extend capacity_pct = todouble(extract(@"(\\d+)%", 1, message))
| where capacity_pct < 80
| project timestamp, capacity_pct;
safety_failures
| join kind=inner capacity_checks on timestamp
| summarize FailureCount = count(), MinCapacity = min(capacity_pct), LastFailure = max(timestamp)
| where FailureCount > 0
'''
    threshold: 1
    frequency: 'PT10M'
    timeWindow: 'PT1H'
    enabled: true
  }
  // ==================== HIGH PRIORITY ALERTS (Severity 2) ====================
  {
    name: 'shr-${functionAppName}-registration-failure-pattern'
    displayName: 'SessionHostReplacer - Registration Failure Pattern'
    description: 'Hosts deployed but consistently failing to register in AVD for >30 minutes'
    severity: 2
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(2h)
| where message has "Deployment succeeded but hosts not yet registered" or 
        message has "hosts still not registered" or
        message has "PendingRegistration"
| summarize OccurrenceCount = count(), 
            FirstOccurrence = min(timestamp),
            LastOccurrence = max(timestamp),
            UnresolvedDuration = datetime_diff('minute', max(timestamp), min(timestamp)),
            sample_message = any(message)
| where UnresolvedDuration > 30
'''
    threshold: 1
    frequency: 'PT15M'
    timeWindow: 'PT2H'
    enabled: true
  }
  {
    name: 'shr-${functionAppName}-blocked-deletions'
    displayName: 'SessionHostReplacer - Blocked Deletions Due to Unresolved Hosts'
    description: 'DeleteFirst mode blocked from deleting more hosts due to unresolved previous deletions'
    severity: 2
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where message has "BLOCKING new deletions" or 
        message has "Cannot delete more hosts while previous deletions have unresolved"
| summarize BlockCount = count(),
            FirstBlock = min(timestamp),
            LastBlock = max(timestamp),
            BlockedDuration = datetime_diff('minute', max(timestamp), min(timestamp)),
            sample_message = any(message)
| where BlockedDuration > 60
'''
    threshold: 1
    frequency: 'PT30M'
    timeWindow: 'PT1H'
    enabled: true
  }
  {
    name: 'shr-${functionAppName}-scaleup-stuck'
    displayName: 'SessionHostReplacer - Progressive Scale-Up Stuck'
    description: 'ConsecutiveSuccesses remains at 0 after multiple runs (5+ runs over 2+ hours)'
    severity: 2
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(6h)
| where message has "Progressive scale-up: Using" and message has "ConsecutiveSuccesses: 0"
| summarize RunCount = count(), 
            FirstRun = min(timestamp),
            LastRun = max(timestamp),
            StuckDuration = datetime_diff('hour', max(timestamp), min(timestamp)),
            sample_message = any(message)
| where RunCount >= 5 and StuckDuration >= 2
'''
    threshold: 1
    frequency: 'PT1H'
    timeWindow: 'PT6H'
    enabled: true
  }
  // ==================== MEDIUM PRIORITY ALERTS (Severity 3) ====================
  {
    name: 'shr-${functionAppName}-graph-permissions-warning'
    displayName: 'SessionHostReplacer - Graph API Permission Warnings'
    description: 'Function attempting device cleanup but lacks Graph API permissions'
    severity: 3
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where (message has "Failed to acquire Graph access token" or
         message has "Get-AccessToken returned null or empty" or
         message has "Device cleanup will be skipped") and
        (message has "Directory.ReadWrite.All" or message has "DeviceManagementManagedDevices.ReadWrite.All")
| summarize WarningCount = count(), LastWarning = max(timestamp), sample_message = any(message)
'''
    threshold: 1
    frequency: 'PT1H'
    timeWindow: 'PT1H'
    enabled: true
  }
  {
    name: 'shr-${functionAppName}-partial-deletion-failures'
    displayName: 'SessionHostReplacer - Partial Deletion Failures'
    description: 'Some hosts failed to delete (VM, Entra, or Intune cleanup incomplete)'
    severity: 3
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(2h)
| where message has "session host deletion(s) failed" or 
        message has "FailedDeletions" or
        message has "IncompleteHosts"
| extend failed_count = toint(extract(@"(\\d+) session host", 1, message))
| where failed_count > 0
| summarize TotalFailures = sum(failed_count), LastFailure = max(timestamp), sample_message = any(message)
'''
    threshold: 1
    frequency: 'PT1H'
    timeWindow: 'PT2H'
    enabled: true
  }
  {
    name: 'shr-${functionAppName}-capacity-below-minimum'
    displayName: 'SessionHostReplacer - Capacity Below Minimum Threshold'
    description: 'Available capacity dropped below configured minimum during replacement'
    severity: 3
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(30m)
| where message has "Current available capacity" and message has "%"
| extend capacity_pct = todouble(extract(@"(\\d+)%", 1, message))
| extend min_capacity_pct = todouble(extract(@"minimum capacity \\((\\d+)%\\)", 1, message))
| where capacity_pct < min_capacity_pct
| summarize MinCapacity = min(capacity_pct), LastOccurrence = max(timestamp), sample_message = any(message)
'''
    threshold: 1
    frequency: 'PT15M'
    timeWindow: 'PT30M'
    enabled: true
  }
  // ==================== INFORMATIONAL ALERTS (Severity 4) ====================
  {
    name: 'shr-${functionAppName}-cycle-complete'
    displayName: 'SessionHostReplacer - Replacement Cycle Complete'
    description: 'All session hosts successfully replaced'
    severity: 4
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where message has "All session hosts are up to date" or
        message has "Session host replacement cycle complete"
| summarize CompletionCount = count(), LastCompletion = max(timestamp)
'''
    threshold: 1
    frequency: 'PT1H'
    timeWindow: 'PT1H'
    enabled: false // Disabled by default
  }
  {
    name: 'shr-${functionAppName}-scaleup-milestone'
    displayName: 'SessionHostReplacer - Progressive Scale-Up Milestone'
    description: 'Progressive scale-up percentage reached milestone (60% or 100%)'
    severity: 4
    query: '''
traces
| where cloud_RoleName == "${functionAppName}"
| where timestamp > ago(1h)
| where message has "Progressive scale-up: Using" and message has "ConsecutiveSuccesses:"
| extend current_pct = toint(extract(@"Using (\\d+)%", 1, message))
| extend successes = toint(extract(@"ConsecutiveSuccesses: (\\d+)", 1, message))
| where successes > 0 and (current_pct == 60 or current_pct == 100)
| summarize LastAdvancement = max(timestamp), Percentage = max(current_pct), sample_message = any(message)
'''
    threshold: 1
    frequency: 'PT1H'
    timeWindow: 'PT1H'
    enabled: false // Disabled by default
  }
]

// Filter alerts based on selected level
var severityFilter = alertLevel == 'Critical' ? [0, 1] : alertLevel == 'High' ? [0, 1, 2] : alertLevel == 'Medium' ? [0, 1, 2, 3] : [0, 1, 2, 3, 4]
var filteredAlerts = filter(allAlerts, alert => contains(severityFilter, alert.severity))

// Deploy alert rules
resource alertRules 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for alert in filteredAlerts: {
  name: alert.name
  location: location
  tags: union(tags, {
    'monitoring-category': 'SessionHostReplacer'
    'alert-severity': string(alert.severity)
  })
  properties: {
    displayName: alert.displayName
    description: alert.description
    severity: alert.severity
    enabled: enableAlerts && alert.enabled
    evaluationFrequency: alert.frequency
    windowSize: alert.timeWindow
    scopes: [
      applicationInsightsResourceId
    ]
    targetResourceTypes: [
      'Microsoft.Insights/components'
    ]
    criteria: {
      allOf: [
        {
          query: alert.query
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: alert.threshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupResourceId
      ]
      customProperties: {
        FunctionApp: functionAppName
        AlertLevel: alertLevel
        DeployedBy: 'SessionHostReplacer-AlertModule'
      }
    }
    autoMitigate: true
    checkWorkspaceAlertsStorageConfigured: false
  }
}]

// Outputs
output deployedAlertCount int = length(filteredAlerts)
output alertNames array = [for alert in filteredAlerts: alert.name]
output alertSeverities array = [for alert in filteredAlerts: alert.severity]

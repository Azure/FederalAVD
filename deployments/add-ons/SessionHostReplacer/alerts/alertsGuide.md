# SessionHostReplacer - Monitoring and Alerting Guide

This document provides recommended alerts and monitoring configurations for the SessionHostReplacer function.

## Prerequisites

- Application Insights enabled for the Function App
- Log Analytics workspace connected
- Action Group configured with notification channels (email, SMS, webhook, etc.)

---

## Alert Categories

### 1. Critical Alerts (Severity 0-1)

#### 1.1 Deployment Failure with Pending Hosts
**Scenario**: Deployment failed and hosts are deleted but not replaced (DeleteFirst mode)

**KQL Query**:
```kusto
traces
| where timestamp > ago(1h)
| where message has "Deployment failed" and message has "pending host mappings"
| summarize FailureCount = count(), LastFailure = max(timestamp) by cloud_RoleName
| where FailureCount > 0
```

**Recommended Configuration**:
- Severity: **0 (Critical)**
- Frequency: Every 5 minutes
- Evaluation period: Last 15 minutes
- Threshold: >= 1 occurrence
- Action: Immediate notification (SMS + Email)

**Impact**: Capacity loss - hosts deleted but not replaced

**Remediation**:
1. Check Function App logs for deployment error details
2. Verify Azure quota/limits not exceeded
3. Check managed identity permissions
4. Verify registration token not expired
5. Consider manual VM deployment to restore capacity

---

#### 1.2 Device Cleanup Failure Blocking Deployment
**Scenario**: DeleteFirst mode cannot proceed because Entra/Intune cleanup failed (Graph API permissions)

**KQL Query**:
```kusto
traces
| where timestamp > ago(30m)
| where message has "Device cleanup verification failed" or message has "cannot safely reuse hostnames"
| summarize FailureCount = count(), LastFailure = max(timestamp), 
            sample_message = any(message) by cloud_RoleName
| where FailureCount > 0
```

**Recommended Configuration**:
- Severity: **0 (Critical)**
- Frequency: Every 5 minutes
- Evaluation period: Last 30 minutes
- Threshold: >= 1 occurrence
- Action: Immediate notification

**Impact**: Deployments completely blocked, capacity cannot be restored

**Remediation**:
1. Run `Set-GraphPermissions.ps1` with managed identity Object ID
2. Verify permissions: `Directory.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`
3. Check for 401/403 errors in logs
4. Verify managed identity has Cloud Device Administrator role

---

#### 1.3 Safety Check Failure with Capacity Loss
**Scenario**: SideBySide mode - new hosts deployed but not Available, old hosts not yet deleted, but pool under capacity

**KQL Query**:
```kusto
traces
| where timestamp > ago(1h)
| where message has "SAFETY CHECK FAILED" 
| join kind=inner (
    traces
    | where timestamp > ago(1h)
    | where message has "Current available capacity" and message has "%"
    | extend capacity_pct = todouble(extract(@"(\d+)%", 1, message))
    | where capacity_pct < 80
) on cloud_RoleName
| summarize FailureCount = count(), MinCapacity = min(capacity_pct), 
            LastFailure = max(timestamp) by cloud_RoleName
```

**Recommended Configuration**:
- Severity: **1 (High)**
- Frequency: Every 10 minutes
- Evaluation period: Last 1 hour
- Threshold: MinCapacity < 80%
- Action: Immediate notification

**Impact**: User experience degraded due to insufficient capacity

**Remediation**:
1. Investigate why new hosts not registering (check VM guest logs)
2. Verify DSC extension ran successfully
3. Check network connectivity from VMs to AVD control plane
4. Force DSC re-run by redeploying template
5. Consider manual intervention to fix registration

---

### 2. High Priority Alerts (Severity 2)

#### 2.1 Registration Failure Pattern
**Scenario**: Hosts deployed but consistently failing to register in AVD

**KQL Query**:
```kusto
traces
| where timestamp > ago(2h)
| where message has "Deployment succeeded but hosts not yet registered" or 
        message has "hosts still not registered" or
        message has "PendingRegistration"
| summarize OccurrenceCount = count(), 
            FirstOccurrence = min(timestamp),
            LastOccurrence = max(timestamp),
            UnresolvedDuration = datetime_diff('minute', max(timestamp), min(timestamp))
            by cloud_RoleName
| where UnresolvedDuration > 30  // Unresolved for more than 30 minutes
```

**Recommended Configuration**:
- Severity: **2 (High)**
- Frequency: Every 15 minutes
- Evaluation period: Last 2 hours
- Threshold: UnresolvedDuration > 30 minutes
- Action: Email notification

**Impact**: Hosts exist but not usable, wasting compute cost

**Remediation**:
1. Check DSC extension status in Azure portal
2. Review VM guest logs (C:\WindowsAzure\Logs\Plugins\Microsoft.Powershell.DSC)
3. Verify registration token valid (not expired)
4. Check firewall rules allow AVD agent communication
5. Verify domain join succeeded (if hybrid)
6. Force DSC retry with forceUpdateTag deployment

---

#### 2.2 Blocked Deletions Due to Unresolved Hosts
**Scenario**: DeleteFirst mode blocked from deleting more hosts because previous deletions not resolved

**KQL Query**:
```kusto
traces
| where timestamp > ago(1h)
| where message has "BLOCKING new deletions" or 
        message has "Cannot delete more hosts while previous deletions have unresolved"
| summarize BlockCount = count(),
            FirstBlock = min(timestamp),
            LastBlock = max(timestamp),
            BlockedDuration = datetime_diff('minute', max(timestamp), min(timestamp))
            by cloud_RoleName
| where BlockedDuration > 60  // Blocked for more than 1 hour
```

**Recommended Configuration**:
- Severity: **2 (High)**
- Frequency: Every 30 minutes
- Evaluation period: Last 1 hour
- Threshold: BlockedDuration > 60 minutes
- Action: Email notification

**Impact**: Replacement cycle stalled, cannot progress until resolved

**Remediation**:
1. Identify unresolved hostnames from logs
2. Check deployment status in Azure portal
3. Verify VMs exist and are running
4. Check if hosts registered in AVD host pool
5. Force registration retry or manual cleanup

---

#### 2.3 Progressive Scale-Up Stuck at Initial Percentage
**Scenario**: ConsecutiveSuccesses remains at 0 after multiple runs (deployments failing repeatedly)

**KQL Query**:
```kusto
traces
| where timestamp > ago(6h)
| where message has "Progressive scale-up: Using" and message has "ConsecutiveSuccesses: 0"
| summarize RunCount = count(), 
            FirstRun = min(timestamp),
            LastRun = max(timestamp),
            StuckDuration = datetime_diff('hour', max(timestamp), min(timestamp))
            by cloud_RoleName
| where RunCount >= 5 and StuckDuration >= 2  // Stuck for 2+ hours with 5+ runs
```

**Recommended Configuration**:
- Severity: **2 (High)**
- Frequency: Every 1 hour
- Evaluation period: Last 6 hours
- Threshold: RunCount >= 5 AND StuckDuration >= 2 hours
- Action: Email notification

**Impact**: Replacement cycle not progressing, pool not being updated

**Remediation**:
1. Investigate why deployments consistently failing
2. Check for recurring error patterns in logs
3. Verify quota limits
4. Review recent configuration changes
5. Consider disabling progressive scale-up temporarily if urgent

---

### 3. Medium Priority Alerts (Severity 3)

#### 3.1 Graph API Permission Warnings
**Scenario**: Function attempting device cleanup but lacks Graph API permissions

**KQL Query**:
```kusto
traces
| where timestamp > ago(1h)
| where (message has "Failed to acquire Graph access token" or
         message has "Get-AccessToken returned null or empty" or
         message has "Device cleanup will be skipped") and
        (message has "Directory.ReadWrite.All" or message has "DeviceManagementManagedDevices.ReadWrite.All")
| summarize WarningCount = count(), LastWarning = max(timestamp),
            sample_message = any(message) by cloud_RoleName
```

**Recommended Configuration**:
- Severity: **3 (Medium)**
- Frequency: Every 1 hour
- Evaluation period: Last 1 hour
- Threshold: >= 1 occurrence
- Action: Email notification

**Impact**: Device cleanup not happening (Entra/Intune hygiene), potential hostname conflicts in future

**Remediation**:
1. Run `Set-GraphPermissions.ps1` script
2. Grant managed identity required Graph permissions
3. Verify permissions propagated (can take 15-30 minutes)
4. Test with `Get-AzureAdDeviceByName` cmdlet

---

#### 3.2 Partial Deletion Failures
**Scenario**: Some hosts failed to delete (VM, Entra, or Intune cleanup incomplete)

**KQL Query**:
```kusto
traces
| where timestamp > ago(2h)
| where message has "session host deletion(s) failed" or 
        message has "FailedDeletions" or
        message has "IncompleteHosts"
| extend failed_count = toint(extract(@"(\d+) session host", 1, message))
| where failed_count > 0
| summarize TotalFailures = sum(failed_count),
            LastFailure = max(timestamp),
            sample_message = any(message) by cloud_RoleName
```

**Recommended Configuration**:
- Severity: **3 (Medium)**
- Frequency: Every 1 hour
- Evaluation period: Last 2 hours
- Threshold: TotalFailures > 0
- Action: Email notification

**Impact**: Orphaned resources, potential cost waste, cleanup required

**Remediation**:
1. Identify failed hostnames from logs
2. Manually verify VM/Entra/Intune state in portal
3. Manual cleanup if needed
4. Check for permission issues or locks
5. Review deletion failure reasons in logs

---

#### 3.3 Capacity Below Minimum Threshold During Replacement
**Scenario**: Available capacity dropped below configured minimum during replacement cycle

**KQL Query**:
```kusto
traces
| where timestamp > ago(30m)
| where message has "Current available capacity" and message has "%"
| extend capacity_pct = todouble(extract(@"(\d+)%", 1, message))
| extend min_capacity_pct = todouble(extract(@"minimum capacity \((\d+)%\)", 1, message))
| where capacity_pct < min_capacity_pct
| summarize MinCapacity = min(capacity_pct), 
            LastOccurrence = max(timestamp),
            sample_message = any(message) by cloud_RoleName
```

**Recommended Configuration**:
- Severity: **3 (Medium)**
- Frequency: Every 15 minutes
- Evaluation period: Last 30 minutes
- Threshold: MinCapacity < configured minimum
- Action: Email notification

**Impact**: User experience may be degraded, load balancing stressed

**Remediation**:
1. Review minimum capacity percentage setting
2. Check if scaling plan capacity more aggressive than expected
3. Verify new hosts deploying and registering correctly
4. Consider pausing replacement cycle during peak hours

---

### 4. Informational Alerts (Severity 4)

#### 4.1 Replacement Cycle Complete
**Scenario**: All hosts successfully replaced

**KQL Query**:
```kusto
traces
| where timestamp > ago(1h)
| where message has "All session hosts are up to date" or
        message has "Session host replacement cycle complete"
| summarize CompletionCount = count(), LastCompletion = max(timestamp) by cloud_RoleName
```

**Recommended Configuration**:
- Severity: **4 (Informational)**
- Frequency: Every 1 hour
- Evaluation period: Last 1 hour
- Threshold: >= 1 occurrence
- Action: Email notification (optional)

**Impact**: None - success notification

---

#### 4.2 Progressive Scale-Up Advancement
**Scenario**: Progressive scale-up percentage increased (milestone achieved)

**KQL Query**:
```kusto
traces
| where timestamp > ago(1h)
| where message has "Progressive scale-up: Using" and message has "ConsecutiveSuccesses:"
| extend current_pct = toint(extract(@"Using (\d+)%", 1, message))
| extend successes = toint(extract(@"ConsecutiveSuccesses: (\d+)", 1, message))
| where successes > 0 and (current_pct == 60 or current_pct == 100)  // Milestone percentages
| summarize LastAdvancement = max(timestamp), 
            Percentage = max(current_pct),
            sample_message = any(message) by cloud_RoleName
```

**Recommended Configuration**:
- Severity: **4 (Informational)**
- Frequency: Every 1 hour
- Evaluation period: Last 1 hour
- Threshold: >= 1 occurrence at milestone percentages
- Action: Email notification (optional)

**Impact**: None - progress notification

---

## Deployment Options

### Option 1: Azure Portal Manual Configuration

1. Navigate to Function App → Monitoring → Alerts
2. Click "New alert rule"
3. Select "Custom log search" condition
4. Paste KQL query from above
5. Configure threshold and evaluation frequency
6. Select Action Group for notifications
7. Set alert name, description, and severity
8. Save alert rule

### Option 2: ARM/Bicep Template (Automated Deployment)

Create an alert rules module that can be deployed alongside SessionHostReplacer:

```bicep
// alertRules.bicep
param functionAppName string
param appInsightsResourceId string
param actionGroupResourceId string
param location string = resourceGroup().location

var alerts = [
  {
    name: 'SessionHostReplacer-DeploymentFailureWithPendingHosts'
    severity: 0
    query: '''
      traces
      | where timestamp > ago(1h)
      | where message has "Deployment failed" and message has "pending host mappings"
      | summarize FailureCount = count() by cloud_RoleName
      | where FailureCount > 0
      '''
    threshold: 1
    frequency: 'PT5M'
    timeWindow: 'PT15M'
  }
  {
    name: 'SessionHostReplacer-DeviceCleanupBlocking'
    severity: 0
    query: '''
      traces
      | where timestamp > ago(30m)
      | where message has "Device cleanup verification failed"
      | summarize FailureCount = count() by cloud_RoleName
      | where FailureCount > 0
      '''
    threshold: 1
    frequency: 'PT5M'
    timeWindow: 'PT30M'
  }
  // Add more alerts here
]

resource alertRules 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for alert in alerts: {
  name: alert.name
  location: location
  properties: {
    displayName: alert.name
    description: 'Auto-generated alert for SessionHostReplacer monitoring'
    severity: alert.severity
    enabled: true
    evaluationFrequency: alert.frequency
    windowSize: alert.timeWindow
    scopes: [
      appInsightsResourceId
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
    }
  }
}]
```

### Option 3: PowerShell Script for Bulk Deployment

```powershell
# Deploy-SessionHostReplacerAlerts.ps1

param(
    [Parameter(Mandatory)]
    [string]$FunctionAppName,
    
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory)]
    [string]$ActionGroupResourceId,
    
    [ValidateSet('Critical', 'High', 'Medium', 'All')]
    [string]$AlertLevel = 'Critical'
)

# Get Function App and App Insights
$functionApp = Get-AzFunctionApp -Name $FunctionAppName -ResourceGroupName $ResourceGroupName
$appInsightsResourceId = $functionApp.ApplicationInsightId

# Define alert configurations (import from JSON or define inline)
$alerts = @(
    @{
        Name = "SessionHostReplacer-DeploymentFailureWithPendingHosts"
        Severity = 0
        Query = @"
traces
| where timestamp > ago(1h)
| where message has "Deployment failed" and message has "pending host mappings"
| summarize FailureCount = count() by cloud_RoleName
| where FailureCount > 0
"@
        Threshold = 1
        Frequency = [TimeSpan]::FromMinutes(5)
        TimeWindow = [TimeSpan]::FromMinutes(15)
    }
    # Add more alerts
)

# Filter by level
if ($AlertLevel -ne 'All') {
    $severityMap = @{
        'Critical' = @(0)
        'High' = @(0, 1, 2)
        'Medium' = @(0, 1, 2, 3)
    }
    $alerts = $alerts | Where-Object { $_.Severity -in $severityMap[$AlertLevel] }
}

# Deploy each alert
foreach ($alert in $alerts) {
    Write-Host "Deploying alert: $($alert.Name)"
    
    $condition = New-AzScheduledQueryRuleCondition `
        -Query $alert.Query `
        -TimeAggregation 'Count' `
        -Operator 'GreaterThanOrEqual' `
        -Threshold $alert.Threshold
    
    New-AzScheduledQueryRule `
        -Name $alert.Name `
        -ResourceGroupName $ResourceGroupName `
        -Location $functionApp.Location `
        -DisplayName $alert.Name `
        -Scope $appInsightsResourceId `
        -Severity $alert.Severity `
        -WindowSize $alert.TimeWindow `
        -EvaluationFrequency $alert.Frequency `
        -Condition $condition `
        -ActionGroup $ActionGroupResourceId `
        -ErrorAction Stop
    
    Write-Host "  ✓ Deployed successfully" -ForegroundColor Green
}

Write-Host "`nDeployed $($alerts.Count) alert(s)" -ForegroundColor Green
```

---

## Monitoring Dashboard

### Recommended Log Analytics Queries for Dashboard

#### Query 1: Replacement Progress Over Time
```kusto
traces
| where timestamp > ago(7d)
| where message has "hosts still need replacement" or message has "All session hosts are up to date"
| extend hosts_remaining = toint(extract(@"(\d+) hosts still need replacement", 1, message))
| extend all_updated = iff(message has "All session hosts are up to date", true, false)
| project timestamp, hosts_remaining = iff(all_updated, 0, hosts_remaining)
| summarize RemainingHosts = max(hosts_remaining) by bin(timestamp, 1h)
| render timechart
```

#### Query 2: Progressive Scale-Up Progression
```kusto
traces
| where timestamp > ago(7d)
| where message has "Progressive scale-up: Using"
| extend percentage = toint(extract(@"Using (\d+)%", 1, message))
| extend successes = toint(extract(@"ConsecutiveSuccesses: (\d+)", 1, message))
| project timestamp, percentage, successes
| summarize Percentage = max(percentage), Successes = max(successes) by bin(timestamp, 1h)
| render timechart
```

#### Query 3: Deployment Success Rate
```kusto
traces
| where timestamp > ago(7d)
| where message has "Deployment submitted" or 
        message has "Previous deployment succeeded" or 
        message has "Previous deployment failed"
| extend status = case(
    message has "succeeded", "Success",
    message has "failed", "Failed",
    message has "submitted", "Pending",
    "Unknown"
)
| summarize SuccessCount = countif(status == "Success"),
            FailureCount = countif(status == "Failed"),
            PendingCount = countif(status == "Pending")
            by bin(timestamp, 1d)
| extend SuccessRate = round(100.0 * SuccessCount / (SuccessCount + FailureCount), 2)
| render columnchart
```

#### Query 4: Capacity Trend During Replacements
```kusto
traces
| where timestamp > ago(7d)
| where message has "Current available capacity"
| extend capacity_pct = todouble(extract(@"(\d+)%", 1, message))
| summarize AvgCapacity = avg(capacity_pct), 
            MinCapacity = min(capacity_pct),
            MaxCapacity = max(capacity_pct)
            by bin(timestamp, 1h)
| render timechart
```

---

## Alert Tuning Recommendations

### 1. Adjust Thresholds Based on Pool Size
- Small pools (< 50 hosts): More sensitive thresholds
- Large pools (> 200 hosts): Higher thresholds to avoid noise

### 2. Business Hours vs. Off-Hours
- Configure different action groups for peak vs. off-peak
- Higher urgency during business hours
- Lower notification frequency overnight

### 3. Alert Fatigue Prevention
- Start with Critical and High severity only
- Add Medium/Informational after team is comfortable
- Use alert suppression rules for known maintenance windows

### 4. Testing Alerts
```powershell
# Trigger test alert by forcing a log entry
Write-Host "Test alert trigger: Deployment failed with 5 pending host mappings"
```

### 5. Integration with ITSM
- Configure action groups to create incidents in ServiceNow/JIRA
- Include runbook links in alert descriptions
- Tag alerts with service names for routing

---

## Troubleshooting Common Alert Issues

### Alert Not Triggering
1. Verify Application Insights receiving logs
2. Check KQL query syntax in Log Analytics
3. Confirm evaluation frequency and time window
4. Verify action group has valid notification channels

### Too Many False Positives
1. Increase threshold or time window
2. Add additional filters to KQL query
3. Use `summarize` to aggregate before alerting
4. Implement alert suppression rules

### Missing Notifications
1. Verify action group notification channels configured
2. Check email/SMS quota limits
3. Review action group activity log for delivery failures
4. Confirm webhook endpoints are reachable

---

## Summary

**Recommended Starting Configuration**:
- Deploy all **Critical** alerts (Severity 0-1)
- Configure one Action Group with email notifications
- Set up Log Analytics dashboard for monitoring trends
- Review and tune alerts after 1 week of operation

**Minimum Viable Monitoring**:
1. Deployment Failure with Pending Hosts (Critical)
2. Device Cleanup Blocking (Critical)
3. Registration Failure Pattern (High)

**Gradual Enhancement**:
- Add Medium severity alerts after 2 weeks
- Implement ITSM integration after 1 month
- Build custom dashboards based on operational needs

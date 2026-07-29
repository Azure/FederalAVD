// AVD Alerts Add-On - Host Pool Alert Rules Module
// Deploys all Log Analytics scheduled query rules for a single AVD host pool.
//
// Alert rules in this module (all scoped to the Log Analytics workspace):
//   Capacity alerts (Pooled pools only - use WVDAgentHealthStatus):
//     - Host pool capacity >= 50%  (Sev 3)
//     - Host pool capacity >= 85%  (Sev 2)
//     - Host pool capacity >= 95%  (Sev 1)
//   Availability alerts:
//     - Session host unhealthy in personal pool  (Sev 1) [Personal pools only]
//     - No resources available for connection  (Sev 1)
//     - VM health check failure  (Sev 1)
//     - User connection failure  (Sev 3)
//     - Disconnected user > 24 hours  (Sev 2)
//     - Disconnected user > 72 hours  (Sev 1)
//   FSLogix alerts (use Event log data from Log Analytics agent / AMA):
//     - Local disk free space <= 10%  (Sev 2)
//     - Local disk free space <= 5%   (Sev 1)
//     - FSLogix profile < 5% free   (EventID 34, Sev 2)
//     - FSLogix profile < 2% free   (EventID 33, Sev 1)
//     - FSLogix profile network issue  (EventID 43, Sev 1)
//     - FSLogix profile disk attach failure  (EventID 52/40, Sev 1)
//     - FSLogix service disabled  (EventID 60, Sev 1)
//     - FSLogix disk compaction failed  (EventID 62/63, Sev 2)
//     - FSLogix profile disk in use by another VM  (EventID 51, Sev 2)
//     - FSLogix corrupted / temp profile            (EventID 28, Sev 2)
//     - FSLogix VHD compaction pre-check failure    (EventID 58/61, Sev 2)
//   Session experience alerts (use WVD checkpoint data directly):
//     - Slow session logon > 2 minutes              (Sev 3)
//
// Capacity alert data source:
//   WVDAgentHealthStatus is emitted by the AVD agent on each session host and is sent to
//   Log Analytics via the host pool diagnostic settings (allLogs, configured by the host pool
//   deployment). It contains ActiveSessions, MaxSessions, AllowNewSessions, and Status per host,
//   allowing load % to be computed without any Automation Account runbook.

// ========== //
// Parameters //
// ========== //

@description('Required. Name of the host pool (not the resource ID).')
param hostPoolName string

@description('Required. Resource ID of the Log Analytics Workspace.')
param logAnalyticsWorkspaceResourceId string

@description('Required. Resource ID of the Action Group for notifications.')
param actionGroupResourceId string

@description('Optional. Prefix prepended to all alert names.')
param alertNamePrefix string = 'AVD'

@description('Optional. Whether alert rules auto-resolve when the condition clears.')
param autoResolveAlert bool = true

@description('Optional. Azure region for the alert rule resources.')
param location string

@description('Optional. When false, host pool capacity alert rules (50%, 85%, 95%) are not deployed.')
param enableCapacityAlerts bool = true

@description('Optional. When false, host availability and VM health alert rules are not deployed.')
param enableAvailabilityAlerts bool = true

@description('Optional. When false, user connection failure and disconnected session alert rules are not deployed.')
param enableConnectionAlerts bool = true

@description('Optional. When false, session host local disk free-space alert rules are not deployed.')
param enableLocalDiskAlerts bool = true

@description('Optional. When false, FSLogix profile alert rules are not deployed.')
param enableFslogixAlerts bool = true

@description('Optional. Whether this is a Pooled or Personal host pool. Capacity alerts (50/85/95%) are only deployed for Pooled pools. The personal session host unhealthy alert is only deployed for Personal pools.')
@allowed(['Pooled', 'Personal'])
param hostPoolType string = 'Pooled'

@description('Required. Full resource ID of the host pool. Used to set the cm-resource-parent tag on alert rules for cost management.')
param hostPoolResourceId string

// ========== //
// Variables  //
// ========== //

var descriptionHeader = 'FederalAVD - Automated Alert\n'

var hostPoolTags = {
  'cm-resource-parent': hostPoolResourceId
}

var actions = {
  actionGroups: [actionGroupResourceId]
}

// ========== //
// Resources  //
// ========== //

// ------------------------------------
// Capacity Alerts (WVDAgentHealthStatus)
// ------------------------------------

resource alertCapacity50 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableCapacityAlerts && hostPoolType == 'Pooled') {
  name: '${alertNamePrefix}-HP-Cap-50Prcnt-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Host Pool Capacity 50% (${hostPoolName})'
    description: '${descriptionHeader}Host pool is at 50-84% capacity. Review scaling plan and available session hosts for ${hostPoolName}.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId contains '${hostPoolName}'
| summarize arg_max(TimeGenerated, *) by SessionHostName
| extend MaxSessions    = tolong(column_ifexists('MaxSessions', 0))
| extend ActiveSessions = tolong(ActiveSessions)
| extend AllowNewSessions = tobool(AllowNewSessions)
| summarize
    TotalActive   = sum(ActiveSessions),
    TotalCapacity = sum(iff(AllowNewSessions and Status == 'Available', MaxSessions, long(0))),
    ResourceId    = any(_ResourceId)
| extend LoadPct = iff(TotalCapacity > 0, round(100.0 * TotalActive / TotalCapacity, 0), 0.0)
| where TotalCapacity > 0 and LoadPct >= 50 and LoadPct < 85
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'TotalActive',   operator: 'Include', values: ['*'] }
            { name: 'TotalCapacity', operator: 'Include', values: ['*'] }
            { name: 'LoadPct',       operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

resource alertCapacity85 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableCapacityAlerts && hostPoolType == 'Pooled') {
  name: '${alertNamePrefix}-HP-Cap-85Prcnt-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Host Pool Capacity 85% (${hostPoolName})'
    description: '${descriptionHeader}Host pool is at 85-94% capacity. Review scaling plan and consider adding session hosts for ${hostPoolName}.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId contains '${hostPoolName}'
| summarize arg_max(TimeGenerated, *) by SessionHostName
| extend MaxSessions    = tolong(column_ifexists('MaxSessions', 0))
| extend ActiveSessions = tolong(ActiveSessions)
| extend AllowNewSessions = tobool(AllowNewSessions)
| summarize
    TotalActive   = sum(ActiveSessions),
    TotalCapacity = sum(iff(AllowNewSessions and Status == 'Available', MaxSessions, long(0))),
    ResourceId    = any(_ResourceId)
| extend LoadPct = iff(TotalCapacity > 0, round(100.0 * TotalActive / TotalCapacity, 0), 0.0)
| where TotalCapacity > 0 and LoadPct >= 85 and LoadPct < 95
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'TotalActive',   operator: 'Include', values: ['*'] }
            { name: 'TotalCapacity', operator: 'Include', values: ['*'] }
            { name: 'LoadPct',       operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

resource alertCapacity95 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableCapacityAlerts && hostPoolType == 'Pooled') {
  name: '${alertNamePrefix}-HP-Cap-95Prcnt-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Host Pool Capacity 95% (${hostPoolName})'
    description: '${descriptionHeader}Host pool is at or above 95% capacity. Immediate action required to add session hosts for ${hostPoolName}.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId contains '${hostPoolName}'
| summarize arg_max(TimeGenerated, *) by SessionHostName
| extend MaxSessions    = tolong(column_ifexists('MaxSessions', 0))
| extend ActiveSessions = tolong(ActiveSessions)
| extend AllowNewSessions = tobool(AllowNewSessions)
| summarize
    TotalActive   = sum(ActiveSessions),
    TotalCapacity = sum(iff(AllowNewSessions and Status == 'Available', MaxSessions, long(0))),
    ResourceId    = any(_ResourceId)
| extend LoadPct = iff(TotalCapacity > 0, round(100.0 * TotalActive / TotalCapacity, 0), 0.0)
| where TotalCapacity > 0 and LoadPct >= 95
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'TotalActive',   operator: 'Include', values: ['*'] }
            { name: 'TotalCapacity', operator: 'Include', values: ['*'] }
            { name: 'LoadPct',       operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// Personal host pool: session host is not in a healthy state
resource alertPersonalUnhealthy 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableAvailabilityAlerts && hostPoolType == 'Personal') {
  name: '${alertNamePrefix}-HP-VM-PersnlAssigndUnhlthy-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Personal Pool Session Host Unhealthy (${hostPoolName})'
    description: '${descriptionHeader}A session host in the personal host pool ${hostPoolName} is not in an Available state. Investigate the affected VM and its health check results.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId contains '${hostPoolName}'
| summarize arg_max(TimeGenerated, Status, _ResourceId) by SessionHostName
| where Status != 'Available' and Status != 'Shutdown'
| project SessionHostName, Status, ResourceId = _ResourceId
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'Status',          operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// ------------------------------------
// Availability Alerts
// ------------------------------------

// No resources available - catastrophic, all hosts unhealthy or at capacity
resource alertNoResourcesAvailable 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableAvailabilityAlerts) {
  name: '${alertNamePrefix}-HP-NoResAvail-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - No Resources Available (${hostPoolName})'
    description: '${descriptionHeader}Catastrophic: no healthy session hosts available for new connections in ${hostPoolName}. Diagnose host pool dependencies immediately.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDConnections
| where TimeGenerated > ago(15m)
| where _ResourceId contains '${hostPoolName}'
| project-away TenantId, SourceSystem
| summarize arg_max(TimeGenerated, *), StartTime = min(iff(State == 'Started', TimeGenerated, datetime(null))), ConnectTime = min(iff(State == 'Connected', TimeGenerated, datetime(null))) by CorrelationId
| join kind=leftouter (
    WVDErrors
    | summarize Errors=make_list(pack('Code', Code, 'CodeSymbolic', CodeSymbolic, 'Time', TimeGenerated, 'Message', Message, 'ServiceError', ServiceError, 'Source', Source)) by CorrelationId
) on CorrelationId
| join kind=leftouter (
    WVDCheckpoints
    | summarize Checkpoints=make_list(pack('Time', TimeGenerated, 'Name', Name, 'Parameters', Parameters, 'Source', Source)) by CorrelationId
    | mv-apply Checkpoints on (
        order by todatetime(Checkpoints['Time']) asc
        | summarize Checkpoints=make_list(Checkpoints)
    )
) on CorrelationId
| project-away CorrelationId1, CorrelationId2
| order by TimeGenerated desc
| where Errors[0].CodeSymbolic == "ConnectionFailedNoHealthyRdshAvailable"
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName', operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// VM health check failure
resource alertVMHealthCheck 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableAvailabilityAlerts) {
  name: '${alertNamePrefix}-HP-VM-HlthChkFailure-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - VM Health Check Failure (${hostPoolName})'
    description: '${descriptionHeader}A session host in ${hostPoolName} is available but a dependent resource (domain, FSLogix, SxS stack, URL check) is in a failed state.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
let MapToDesc = (idx: long) {
    case(idx == 0, "DomainJoin",
    idx == 1, "DomainTrust",
    idx == 2, "FSLogix",
    idx == 3, "SxSStack",
    idx == 4, "URLCheck",
    idx == 5, "GenevaAgent",
    idx == 6, "DomainReachable",
    idx == 7, "WebRTCRedirector",
    idx == 8, "SxSStackEncryption",
    idx == 9, "IMDSReachable",
    idx == 10, "MSIXPackageStaging",
    "InvalidIndex")
};
WVDAgentHealthStatus
| where TimeGenerated > ago(10m)
| where Status != 'Available'
| where AllowNewSessions == true
| extend CheckFailed = parse_json(SessionHostHealthCheckResult)
| mv-expand CheckFailed
| where CheckFailed.AdditionalFailureDetails.ErrorCode != 0
| extend HealthCheckName = tolong(CheckFailed.HealthCheckName)
| extend HealthCheckResult = tolong(CheckFailed.HealthCheckResult)
| extend HealthCheckDesc = MapToDesc(HealthCheckName)
| where HealthCheckDesc != "InvalidIndex"
| where _ResourceId contains '${hostPoolName}'
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" HostPoolResourceGroup "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
| parse SessionHostResourceId with "/subscriptions/" HostSubscription "/resourceGroups/" SessionHostRG "/providers/Microsoft.Compute/virtualMachines/" SessionHostName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'HealthCheckDesc', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
            { name: 'SessionHostRG', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// User connection failed
resource alertConnectionFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-Usr-ConnctnFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - User Connection Failed (${hostPoolName})'
    description: '${descriptionHeader}A user failed to connect to a session host in ${hostPoolName}. If frequent, investigate network latency (>150ms) and session host availability.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDConnections
| project-away TenantId, SourceSystem
| summarize arg_max(TimeGenerated, *), StartTime = min(iff(State == 'Started', TimeGenerated, datetime(null))), ConnectTime = min(iff(State == 'Connected', TimeGenerated, datetime(null))) by CorrelationId
| join kind=leftouter (
    WVDErrors
    | summarize Errors=make_list(pack('Code', Code, 'CodeSymbolic', CodeSymbolic, 'Time', TimeGenerated, 'Message', Message, 'ServiceError', ServiceError, 'Source', Source)) by CorrelationId
) on CorrelationId
| join kind=leftouter (
    WVDCheckpoints
    | summarize Checkpoints=make_list(pack('Time', TimeGenerated, 'Name', Name, 'Parameters', Parameters, 'Source', Source)) by CorrelationId
    | mv-apply Checkpoints on (
        order by todatetime(Checkpoints['Time']) asc
        | summarize Checkpoints=make_list(Checkpoints)
    )
) on CorrelationId
| project-away CorrelationId1, CorrelationId2
| order by TimeGenerated desc
| where TimeGenerated > ago(15m)
| extend ResourceGroup=tostring(split(_ResourceId, '/')[4])
| extend HostPool=tostring(split(_ResourceId, '/')[8])
| where HostPool =~ '${hostPoolName}'
| where isnotempty(Errors)
| extend ErrorShort=tostring(Errors[0].CodeSymbolic)
| extend ErrorMessage=tostring(Errors[0].Message)
| project TimeGenerated, HostPool, ResourceGroup, UserName, ClientOS, ClientVersion, ClientSideIPAddress, ConnectionType, ErrorShort, ErrorMessage
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'HostPool', operator: 'Include', values: ['*'] }
            { name: 'UserName', operator: 'Include', values: ['*'] }
            { name: 'ErrorShort', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// Disconnected user > 24 hours
resource alertDisconnectedUser24h 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-DiscUser24Hrs-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Disconnected User Over 24 Hours (${hostPoolName})'
    description: '${descriptionHeader}A user in ${hostPoolName} has a disconnected session lasting more than 24 hours. Verify Remote Desktop session limit policies are applied. This could affect scaling plans.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDConnections
| where TimeGenerated > ago(24h)
| where State == "Connected"
| where _ResourceId contains '${hostPoolName}'
| project CorrelationId, UserName, ConnectionType, StartTime=TimeGenerated, SessionHostName
| join (
    WVDConnections
    | where State == "Completed"
    | project EndTime=TimeGenerated, CorrelationId
) on CorrelationId
| project Duration = EndTime - StartTime, ConnectionType, UserName, SessionHostName
| where Duration >= timespan(24:00:00)
| sort by Duration desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName', operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// Disconnected user > 72 hours
resource alertDisconnectedUser72h 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-DiscUser72Hrs-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Disconnected User Over 72 Hours (${hostPoolName})'
    description: '${descriptionHeader}A user in ${hostPoolName} has a disconnected session lasting more than 72 hours. This likely indicates stale sessions blocking scaling automation. Verify session limit policies.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDConnections
| where TimeGenerated > ago(24h)
| where State == "Connected"
| where _ResourceId contains '${hostPoolName}'
| project CorrelationId, UserName, ConnectionType, StartTime=TimeGenerated, SessionHostName
| join (
    WVDConnections
    | where State == "Completed"
    | project EndTime=TimeGenerated, CorrelationId
) on CorrelationId
| project Duration = EndTime - StartTime, ConnectionType, UserName, SessionHostName
| where Duration >= timespan(72:00:00)
| sort by Duration desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName', operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// ------------------------------------
// Local Disk Space Alerts
// ------------------------------------

// Local C: drive free space <= 10%
resource alertLocalDiskFree10 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableLocalDiskAlerts) {
  name: '${alertNamePrefix}-HP-VM-LocDskFree10Prcnt-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - VM Local Disk Free <= 10% (${hostPoolName})'
    description: '${descriptionHeader}A session host in ${hostPoolName} has 10% or less free space on the C: drive. Review local profiles, temp files, and application logs consuming disk space.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName !contains "D:" and InstanceName !contains "_Total"
| where CounterValue <= 10.00
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| summarize arg_max(TimeGenerated, *) by ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, CounterValue, subscription, ResourceGroup, TimeGenerated
| join kind=leftouter (
    WVDAgentHealthStatus
    | where TimeGenerated > ago(15m)
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool, _ResourceId
) on ComputerName
| where ComputerName1 contains ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// Local C: drive free space <= 5%
resource alertLocalDiskFree5 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableLocalDiskAlerts) {
  name: '${alertNamePrefix}-HP-VM-LocDskFree5Prcnt-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - VM Local Disk Free <= 5% (${hostPoolName})'
    description: '${descriptionHeader}CRITICAL: A session host in ${hostPoolName} has 5% or less free space on the C: drive. Immediate action required to free disk space.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName !contains "D:" and InstanceName !contains "_Total"
| where CounterValue <= 5.00
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| summarize arg_max(TimeGenerated, *) by ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, CounterValue, subscription, ResourceGroup, TimeGenerated
| join kind=leftouter (
    WVDAgentHealthStatus
    | where TimeGenerated > ago(15m)
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool, _ResourceId
) on ComputerName
| where ComputerName1 contains ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// ------------------------------------
// FSLogix Profile Alerts
// ------------------------------------

// FSLogix profile < 5% free (EventID 34, Warning) - enriched with user and storage account context
// Joins FSLogix warnings with WVDConnections to identify which user's profile is nearly full,
// on which session host, and pointing to which storage account.
resource alertFSLogixProfile5PctFree 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf5PrcntFree-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile < 5% Free Space (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 34 in ${hostPoolName}: a user profile VHD has less than 5% free space. The alert includes the affected user, profile container, and storage account. Expand the VHD or clean up profile data.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
let fslogixWarnings =
    Event
    | where Source == "Microsoft-FSLogix-Apps"
    | where EventID == 34
    | extend
        StorageAccount = extract(@"\\\\([^\\]+\.file\.core\.[^\\]+)", 1, RenderedDescription),
        ProfileRaw     = extract(@"profilecontainers\\([^\\]+)", 1, RenderedDescription)
    | extend ProfileID = tostring(split(ProfileRaw, "_")[0])
    | project EventTime = TimeGenerated, Computer, ProfileID, StorageAccount, EventID, RenderedDescription;
fslogixWarnings
| join kind=inner (
    WVDConnections
    | where _ResourceId contains '${hostPoolName}'
    | where State == "Connected"
    | project ConnTime = TimeGenerated, UserName, SessionHostName, ResourceId = _ResourceId
) on $left.Computer == $right.SessionHostName
| extend TimeDiff = abs(datetime_diff('minute', EventTime, ConnTime))
| where TimeDiff <= 30
| summarize arg_min(TimeDiff, *) by EventTime, Computer
| project
    EventTime,
    UserName,
    ProfileID,
    SessionHostName = Computer,
    StorageAccount,
    EventID,
    RenderedDescription,
    ResourceId
| order by EventTime desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',        operator: 'Include', values: ['*'] }
            { name: 'ProfileID',       operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'StorageAccount',  operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix profile < 2% free (EventID 33, Error) - enriched with user and storage account context
// Joins FSLogix errors with WVDConnections to identify which user's profile is critically full,
// on which session host, and pointing to which storage account.
resource alertFSLogixProfile2PctFree 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf2PrcntFree-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile < 2% Free Space (${hostPoolName})'
    description: '${descriptionHeader}CRITICAL: FSLogix Event ID 33 in ${hostPoolName}: a user profile VHD has less than 2% free space. The alert includes the affected user, profile container, and storage account. Expand the VHD or clean up profile data immediately.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
let fslogixErrors =
    Event
    | where Source == "Microsoft-FSLogix-Apps"
    | where EventID == 33
    | extend
        StorageAccount = extract(@"\\\\([^\\]+\.file\.core\.[^\\]+)", 1, RenderedDescription),
        ProfileRaw     = extract(@"profilecontainers\\([^\\]+)", 1, RenderedDescription)
    | extend ProfileID = tostring(split(ProfileRaw, "_")[0])
    | project EventTime = TimeGenerated, Computer, ProfileID, StorageAccount, EventID, RenderedDescription;
fslogixErrors
| join kind=inner (
    WVDConnections
    | where _ResourceId contains '${hostPoolName}'
    | where State == "Connected"
    | project ConnTime = TimeGenerated, UserName, SessionHostName, ResourceId = _ResourceId
) on $left.Computer == $right.SessionHostName
| extend TimeDiff = abs(datetime_diff('minute', EventTime, ConnTime))
| where TimeDiff <= 30
| summarize arg_min(TimeDiff, *) by EventTime, Computer
| project
    EventTime,
    UserName,
    ProfileID,
    SessionHostName = Computer,
    StorageAccount,
    EventID,
    RenderedDescription,
    ResourceId
| order by EventTime desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',        operator: 'Include', values: ['*'] }
            { name: 'ProfileID',       operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'StorageAccount',  operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix profile network issue (EventID 43)
resource alertFSLogixNetworkIssue 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-NetwrkIssue-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Network Issue (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 43: a session host in ${hostPoolName} cannot reach the FSLogix profile storage. Verify network connectivity between the session hosts and the storage account.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID == 43
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, RenderedDescription, subscription, ResourceGroup, TimeGenerated, _ResourceId
| join kind=leftouter (
    WVDAgentHealthStatus
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool
) on ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix profile disk failed to attach (EventID 52 or 40)
resource alertFSLogixDiskAttachFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-FailAttVHD-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Disk Failed to Attach (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 52 or 40: the profile VHD failed to attach for a session host in ${hostPoolName}. Investigate FSLogix errors for details.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID == 52 or EventID == 40
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, RenderedDescription, subscription, ResourceGroup, TimeGenerated, _ResourceId
| join kind=leftouter (
    WVDAgentHealthStatus
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool
) on ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix service disabled (EventID 60)
resource alertFSLogixServiceDisabled 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-SvcDisabled-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Service Disabled (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 60: the FSLogix Profile service is disabled on a session host in ${hostPoolName}. Re-enable and start the FSLogix service immediately.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Warning"
| where EventID == 60
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, RenderedDescription, subscription, ResourceGroup, TimeGenerated, _ResourceId
| join kind=leftouter (
    WVDAgentHealthStatus
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool
) on ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix disk compaction failed (EventID 62 or 63)
resource alertFSLogixDiskCompaction 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-DskCmpFail-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Disk Compaction Failed (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 62 or 63: profile disk compaction failed on a session host in ${hostPoolName}. The disk was marked for compaction but the operation failed.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID == 62 or EventID == 63
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, RenderedDescription, subscription, ResourceGroup, TimeGenerated, _ResourceId
| join kind=leftouter (
    WVDAgentHealthStatus
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool
) on ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix profile disk in use by another VM (EventID 51)
resource alertFSLogixDiskInUse 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-DskInUse-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Disk In Use by Another VM (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 51: a profile VHD is already attached to another VM in ${hostPoolName}. Ensure the user is not connected to multiple host pools sharing the same profile.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Operational"
| where EventLevelName == "Warning"
| where EventID == 51
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName=tolower(ComputerName)
| project ComputerName, RenderedDescription, subscription, ResourceGroup, TimeGenerated, _ResourceId
| join kind=leftouter (
    WVDAgentHealthStatus
    | where _ResourceId contains '${hostPoolName}'
    | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
    | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
    | extend ComputerName=tolower(ComputerName)
    | summarize arg_max(TimeGenerated, *) by ComputerName
    | project VMresourceGroup, ComputerName, HostPool
) on ComputerName
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName', operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix corrupted / temp profile (EventID 28)
// Uses a two-step lookup to correlate the error with a storage account path
// (EventID 28 itself does not include the path, so we find a nearby event that does),
// then joins with WVDConnections to identify the affected user.
resource alertFSLogixCorruptedProfile 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-Corrupt-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Corrupted / Temp Profile (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 28 in ${hostPoolName}: a user profile VHD is corrupted or could not be mounted and the user was loaded into a temporary profile. Data written during this session will be lost. Investigate and repair the profile VHD.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
let fslogixErrors =
    Event
    | where Source == "Microsoft-FSLogix-Apps"
    | where EventID == 28
    | extend ProfileID = tostring(extract(@"Username:\s*([^\s]+)", 1, RenderedDescription))
    | project EventTime = TimeGenerated, Computer, ProfileID, EventID, RenderedDescription;
let storageLookup =
    Event
    | where Source == "Microsoft-FSLogix-Apps"
    | where RenderedDescription has ".file.core."
    | extend StorageAccount = extract(@"\\\\([^\\]+\.file\.core\.[^\\]+)", 1, RenderedDescription)
    | where isnotempty(StorageAccount)
    | project PathTime = TimeGenerated, Computer, StorageAccount;
fslogixErrors
| join kind=leftouter (storageLookup) on Computer
| extend PathDiff = abs(datetime_diff('minute', EventTime, PathTime))
| where PathDiff <= 60
| join kind=inner (
    WVDConnections
    | where _ResourceId contains '${hostPoolName}'
    | where State == "Connected"
    | project ConnTime = TimeGenerated, UserName, SessionHostName, ResourceId = _ResourceId
) on $left.Computer == $right.SessionHostName
| extend TimeDiff = abs(datetime_diff('minute', EventTime, ConnTime))
| where TimeDiff <= 30
| summarize arg_min(TimeDiff, *) by EventTime, Computer
| project
    EventTime,
    UserName,
    ProfileID,
    SessionHostName = Computer,
    StorageAccount,
    EventID,
    RenderedDescription,
    ResourceId
| order by EventTime desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',        operator: 'Include', values: ['*'] }
            { name: 'ProfileID',       operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'StorageAccount',  operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// FSLogix VHD compaction pre-check failure (EventID 58, 61)
// EventID 58: VHD compaction aborted due to insufficient free space to perform the operation.
// EventID 61: VHD compaction aborted because the VHD is currently in use.
// These are pre-conditions that will prevent compaction from completing and can mask a disk space problem.
// EventIDs 60, 62, 63 have dedicated alerts; this rule covers the earlier-stage pre-check failures.
resource alertFSLogixCompactionPrecheck 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLgxProf-CmpctPre-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix VHD Compaction Pre-Check Failure (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 58 or 61 in ${hostPoolName}: VHD disk compaction was aborted before starting, either because the host disk lacks free space for the operation (58) or the VHD is in use (61). Profile VHDs will grow unbounded until compaction can complete.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
let fslogixErrors =
    Event
    | where Source == "Microsoft-FSLogix-Apps"
    | where EventID in (58, 61)
    | extend
        StorageAccount = extract(@"\\\\([^\\]+\.file\.core\.[^\\]+)", 1, RenderedDescription),
        ProfileRaw     = extract(@"profilecontainers\\([^\\]+)", 1, RenderedDescription)
    | extend ProfileID = tostring(split(ProfileRaw, "_")[0])
    | project EventTime = TimeGenerated, Computer, ProfileID, StorageAccount, EventID, RenderedDescription;
fslogixErrors
| join kind=inner (
    WVDConnections
    | where _ResourceId contains '${hostPoolName}'
    | where State == "Connected"
    | project ConnTime = TimeGenerated, UserName, SessionHostName, ResourceId = _ResourceId
) on $left.Computer == $right.SessionHostName
| extend TimeDiff = abs(datetime_diff('minute', EventTime, ConnTime))
| where TimeDiff <= 30
| summarize arg_min(TimeDiff, *) by EventTime, Computer
| project
    EventTime,
    UserName,
    ProfileID,
    SessionHostName = Computer,
    StorageAccount,
    EventID,
    RenderedDescription,
    ResourceId
| order by EventTime desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',        operator: 'Include', values: ['*'] }
            { name: 'ProfileID',       operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'StorageAccount',  operator: 'Include', values: ['*'] }
            { name: 'EventID',         operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

// Slow session logon - time from connection start to productive desktop > 2 minutes
// Uses WVDCheckpoints ShellReady / RdpShellAppExecuted to measure full logon time
// (includes Windows logon, profile load, GPO processing, startup scripts).
// Fires at Sev 3 as an early warning; repeated occurrences indicate profile bloat, GPO issues,
// or storage latency on the FSLogix share.
resource alertSlowSessionLogon 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-Usr-SlowLogon-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Slow Session Logon > 2 Minutes (${hostPoolName})'
    description: '${descriptionHeader}A user in ${hostPoolName} took more than 2 minutes from connection start to productive desktop. Common causes: FSLogix profile bloat, GPO processing delay, slow storage, or startup scripts. Review FSLogix profile sizes and storage latency.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: '''
WVDConnections
| where TimeGenerated > ago(30m)
| where _ResourceId contains '${hostPoolName}'
| where State == "Started"
| project CorrelationId, UserName, SessionHostName, StartTime = TimeGenerated, ResourceId = _ResourceId
| join kind=inner (
    WVDCheckpoints
    | where _ResourceId contains '${hostPoolName}'
    | where Name =~ "ShellReady"
        or (Name =~ "LaunchExecutable" and tostring(Parameters.connectionStage) == "RdpShellAppExecuted")
        or Name =~ "RdpShellAppExecuted"
    | summarize ShellReadyTime = min(TimeGenerated) by CorrelationId
) on CorrelationId
| extend LogonSeconds = datetime_diff('second', ShellReadyTime, StartTime)
| where LogonSeconds > 120
| project
    StartTime,
    UserName,
    SessionHostName,
    LogonSeconds,
    LogonMinutes = round(LogonSeconds / 60.0, 1),
    ResourceId
| order by LogonSeconds desc
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',        operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'LogonMinutes',    operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: actions
  }
}

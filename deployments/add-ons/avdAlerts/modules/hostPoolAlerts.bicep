// AVD Alerts Add-On - Host Pool Alert Rules Module
// Deploys all Log Analytics scheduled query rules for a single AVD host pool.
//
// Alert rules in this module (all scoped to the Log Analytics workspace):
//   Capacity alerts (Pooled pools only - use WVDAgentHealthStatus):
//     - Host pool capacity >= 50%  (Sev 3)
//     - Host pool capacity >= 85%  (Sev 2)
//     - Host pool capacity >= 95%  (Sev 1)
//   Availability alerts:
//     - Session host unhealthy  (Sev 1) [all pool types]
//     - No resources available for connection  (Sev 1)
//     - VM health check failure  (Sev 1)
//   Connection alerts (gated by enableConnectionAlerts):
//     - User auth / service connection failed  (>= 3 per user in 15 min, Sev 3)
//     - Session host connection failed         (>= 3 per host in 15 min, Sev 2)
//     - Disconnected user > configured threshold (default 8h, max 47h)  (Sev 3)
//     - Slow session logon > configured threshold (default 2 min)  (Sev 3)
//   FSLogix alerts (use Event log data from Log Analytics agent / AMA):
//     - FSLogix profile < 5% free   (EventID 34, Sev 2)
//     - FSLogix profile < 2% free   (EventID 33, Sev 1)
//     - FSLogix profile network issue  (EventID 43, Sev 1)
//     - FSLogix profile disk attach failure  (EventID 52/40, Sev 1)
//     - FSLogix VHD reattach failed (>= 3 events per host)  (EventID 56, Sev 2)
//     - FSLogix service disabled  (EventID 60, Sev 1)
//     - FSLogix disk compaction failed  (EventID 62/63, Sev 2)
//     - FSLogix profile disk in use by another VM  (EventID 51, Sev 2)
//     - FSLogix corrupted / temp profile            (EventID 28, Sev 1)
//     - FSLogix VHD compaction pre-check failure    (EventID 58/61, Sev 3)
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

@description('Optional. Logon duration threshold in minutes. The slow logon alert fires when a user takes longer than this value to reach a productive desktop. Minimum 1, maximum 30.')
@minValue(1)
@maxValue(30)
param slowLogonThresholdMinutes int = 2

@description('Optional. Hours after which a disconnected-but-not-logged-off session triggers an alert. Minimum 1, maximum 47.')
@minValue(1)
@maxValue(47)
param disconnectedSessionAlertThresholdHours int = 8

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

var descriptionHeader = 'AVD - Automated Alert\n'

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
  name: '${alertNamePrefix}-HP-Cap-50pct-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Host Pool Capacity 50% (${hostPoolName})'
    description: '${descriptionHeader}Host pool is at 50-84% capacity for 15 or more continuous minutes. Review scaling plan and available session hosts for ${hostPoolName}.'
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
          query: replace('''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId has "__POOL__"
| summarize arg_max(TimeGenerated, *) by SessionHostName
| extend MaxSessions    = tolong(column_ifexists('MaxSessions', 0))
| extend ActiveSessions = tolong(ActiveSessions)
| extend AllowNewSessions = tobool(AllowNewSessions)
| summarize
    TimeGenerated = max(TimeGenerated),
    TotalActive   = sum(ActiveSessions),
    TotalCapacity = sum(iff(AllowNewSessions and Status == 'Available', MaxSessions, long(0))),
    ResourceId    = any(_ResourceId)
| extend LoadPct = iff(TotalCapacity > 0, round(100.0 * TotalActive / TotalCapacity, 0), 0.0)
| where TotalCapacity > 0 and LoadPct >= 50 and LoadPct < 85
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'TotalActive',   operator: 'Include', values: ['*'] }
            { name: 'TotalCapacity', operator: 'Include', values: ['*'] }
            { name: 'LoadPct',       operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 3, minFailingPeriodsToAlert: 3 }
        }
      ]
    }
    actions: actions
  }
}

resource alertCapacity85 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableCapacityAlerts && hostPoolType == 'Pooled') {
  name: '${alertNamePrefix}-HP-Cap-85pct-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Host Pool Capacity 85% (${hostPoolName})'
    description: '${descriptionHeader}Host pool is at 85-94% capacity for 15 or more continuous minutes. Review scaling plan and consider adding session hosts for ${hostPoolName}.'
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
          query: replace('''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId has "__POOL__"
| summarize arg_max(TimeGenerated, *) by SessionHostName
| extend MaxSessions    = tolong(column_ifexists('MaxSessions', 0))
| extend ActiveSessions = tolong(ActiveSessions)
| extend AllowNewSessions = tobool(AllowNewSessions)
| summarize
    TimeGenerated = max(TimeGenerated),
    TotalActive   = sum(ActiveSessions),
    TotalCapacity = sum(iff(AllowNewSessions and Status == 'Available', MaxSessions, long(0))),
    ResourceId    = any(_ResourceId)
| extend LoadPct = iff(TotalCapacity > 0, round(100.0 * TotalActive / TotalCapacity, 0), 0.0)
| where TotalCapacity > 0 and LoadPct >= 85 and LoadPct < 95
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'TotalActive',   operator: 'Include', values: ['*'] }
            { name: 'TotalCapacity', operator: 'Include', values: ['*'] }
            { name: 'LoadPct',       operator: 'Include', values: ['*'] }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 3, minFailingPeriodsToAlert: 3 }
        }
      ]
    }
    actions: actions
  }
}

resource alertCapacity95 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableCapacityAlerts && hostPoolType == 'Pooled') {
  name: '${alertNamePrefix}-HP-Cap-95pct-${hostPoolName}'
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
          query: replace('''
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| where _ResourceId has "__POOL__"
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
''', '__POOL__', hostPoolName)
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
resource alertSessionHostUnhealthy 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableAvailabilityAlerts) {
  name: '${alertNamePrefix}-HP-Host-Unhealthy-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Session Host Unhealthy (${hostPoolName})'
    description: '${descriptionHeader}A session host in ${hostPoolName} has been in a non-Available, non-Shutdown state for 15 or more continuous minutes and is not in drain mode (AllowNewSessions == true). Newly deployed hosts are excluded until they have been visible in the health status data for at least 15 minutes. Investigate WVDAgentHealthStatus and the VM directly.'
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
          query: replace('''
WVDAgentHealthStatus
| where TimeGenerated > ago(20m)
| where _ResourceId has "__POOL__"
| where AllowNewSessions == true
| where Status != 'Shutdown'
| summarize 
    arg_max(TimeGenerated, Status, _ResourceId),
    LastAvailable = maxif(TimeGenerated, Status == 'Available'),
    FirstSeen = min(TimeGenerated)
  by SessionHostName
| where Status != 'Available'
| where (isnull(LastAvailable) and FirstSeen <= ago(15m)) or LastAvailable <= ago(15m)
| project SessionHostName, Status, ResourceId = _ResourceId
''', '__POOL__', hostPoolName)
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
  name: '${alertNamePrefix}-HP-Host-NoResources-${hostPoolName}'
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
          query: replace('''
WVDConnections
| where TimeGenerated > ago(15m)
| where _ResourceId has "__POOL__"
| summarize arg_max(TimeGenerated, UserName, SessionHostName, _ResourceId) by CorrelationId
| join kind=inner (
    WVDErrors
    | where TimeGenerated > ago(15m)
    | where CodeSymbolic == "ConnectionFailedNoHealthyRdshAvailable"
    | summarize by CorrelationId
) on CorrelationId
| project UserName, SessionHostName, ResourceId = _ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName', operator: 'Include', values: ['*'] }
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
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

// VM health check failure
resource alertVMHealthCheck 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableAvailabilityAlerts) {
  name: '${alertNamePrefix}-HP-Host-HealthCheckFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Host Health Check Failed (${hostPoolName})'
    description: '${descriptionHeader}A session host in ${hostPoolName} is available but a dependent resource (domain, FSLogix, SxS stack, URL check) is in a failed state. Only fires for hosts not in drain mode; requires 3 consecutive evaluations (15 minutes) before alerting.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
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
| where TimeGenerated > ago(5m)
| where Status != 'Available'
| where AllowNewSessions == true
| extend CheckFailed = parse_json(SessionHostHealthCheckResult)
| mv-expand CheckFailed
| where CheckFailed.AdditionalFailureDetails.ErrorCode != 0
| extend HealthCheckName = tolong(CheckFailed.HealthCheckName)
| extend HealthCheckResult = tolong(CheckFailed.HealthCheckResult)
| extend HealthCheckDesc = MapToDesc(HealthCheckName)
| where HealthCheckDesc != "InvalidIndex"
| where _ResourceId has "__POOL__"
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" HostPoolResourceGroup "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
| parse SessionHostResourceId with "/subscriptions/" HostSubscription "/resourceGroups/" SessionHostRG "/providers/Microsoft.Compute/virtualMachines/" SessionHostName
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'SessionHostName', operator: 'Include', values: ['*'] }
            { name: 'HealthCheckDesc', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
            { name: 'SessionHostRG', operator: 'Include', values: ['*'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: { numberOfEvaluationPeriods: 3, minFailingPeriodsToAlert: 3 }
        }
      ]
    }
    actions: actions
  }
}

// User auth / service connection failed
// Fires when the same user accumulates 3+ failures at the gateway/broker level
// (SessionHostName is empty = no session host was assigned).
// Indicates account, MFA, Conditional Access, or AVD service issues - not a VM problem.
resource alertConnAuthFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-Conn-AuthFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - User Auth / Service Connection Failed (${hostPoolName})'
    description: '${descriptionHeader}A user in ${hostPoolName} failed to connect 3 or more times at the gateway or broker level in the last 15 minutes (no session host was assigned). Likely causes: MFA failure, Conditional Access policy block, expired token, or no available session hosts. Review the UserName and ErrorCodes dimensions.'
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
          query: replace('''
WVDConnections
| project-away TenantId, SourceSystem
| summarize arg_max(TimeGenerated, *) by CorrelationId
| join kind=leftouter (
    WVDErrors
    | summarize Errors=make_list(pack('Code', Code, 'CodeSymbolic', CodeSymbolic, 'Time', TimeGenerated, 'Message', Message, 'ServiceError', ServiceError, 'Source', Source)) by CorrelationId
) on CorrelationId
| project-away CorrelationId1
| where TimeGenerated > ago(15m)
| extend ResourceGroup=tostring(split(_ResourceId, '/')[4])
| extend HostPool=tostring(split(_ResourceId, '/')[8])
| where HostPool =~ "__POOL__"
| where isnotempty(Errors)
| where isempty(SessionHostName)
| extend ErrorShort=tostring(Errors[0].CodeSymbolic)
| summarize FailureCount=count(),
            ErrorCodes=make_set(ErrorShort, 5),
            ResourceGroup=take_any(ResourceGroup)
  by HostPool, UserName
| where FailureCount >= 3
| project HostPool, ResourceGroup, UserName, FailureCount, ErrorCodes=tostring(ErrorCodes)
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'HostPool', operator: 'Include', values: ['*'] }
            { name: 'UserName', operator: 'Include', values: ['*'] }
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

// Session host connection failed
// Fires when a session host accumulates 3+ connection failures after host assignment.
// SessionHostName is populated = the broker assigned a host but the connection failed on the VM side.
// Indicates RDP stack crash, FSLogix profile load failure, or VM networking issues.
resource alertConnHostFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-Conn-HostFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Session Host Connection Failed (${hostPoolName})'
    description: '${descriptionHeader}A session host in ${hostPoolName} has had 3 or more post-assignment connection failures in the last 15 minutes. Likely causes: RDP stack crash, FSLogix profile load failure, or VM networking issue. Review the SessionHost dimension and investigate the VM directly.'
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
          query: replace('''
WVDConnections
| project-away TenantId, SourceSystem
| summarize arg_max(TimeGenerated, *) by CorrelationId
| join kind=leftouter (
    WVDErrors
    | summarize Errors=make_list(pack('Code', Code, 'CodeSymbolic', CodeSymbolic, 'Time', TimeGenerated, 'Message', Message, 'ServiceError', ServiceError, 'Source', Source)) by CorrelationId
) on CorrelationId
| project-away CorrelationId1
| where TimeGenerated > ago(15m)
| extend ResourceGroup=tostring(split(_ResourceId, '/')[4])
| extend HostPool=tostring(split(_ResourceId, '/')[8])
| where HostPool =~ "__POOL__"
| where isnotempty(Errors)
| where isnotempty(SessionHostName)
| extend ErrorShort=tostring(Errors[0].CodeSymbolic)
| extend SessionHost=tostring(split(SessionHostName, '.')[0])
| summarize FailureCount=count(),
            ErrorCodes=make_set(ErrorShort, 5),
            AffectedUsers=make_set(UserName, 10),
            ResourceGroup=take_any(ResourceGroup)
  by HostPool, SessionHost
| where FailureCount >= 3
| project HostPool, ResourceGroup, SessionHost, FailureCount, AffectedUsers=tostring(AffectedUsers), ErrorCodes=tostring(ErrorCodes)
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'HostPool',    operator: 'Include', values: ['*'] }
            { name: 'SessionHost', operator: 'Include', values: ['*'] }
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

// Disconnected user > configured threshold (default disconnectedSessionAlertThresholdHours hours)
resource alertDisconnectedUser24h 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-Sess-Disconnected${disconnectedSessionAlertThresholdHours}h-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Session Disconnected > ${disconnectedSessionAlertThresholdHours}h (${hostPoolName})'
    description: '${descriptionHeader}A user in ${hostPoolName} has been disconnected but not logged off for more than ${disconnectedSessionAlertThresholdHours} hours. Verify Remote Desktop session timeout and logoff policies are applied. This could affect scaling plans.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace(replace('''
WVDConnections
| where TimeGenerated > ago(48h)
| where _ResourceId has "__POOL__"
| summarize arg_max(TimeGenerated, State, SessionHostName, _ResourceId) by UserName, SessionHostName
| where State == "Disconnected"
| where TimeGenerated < ago(__THRESHOLD__h)
| extend DisconnectedHours = round(datetime_diff('minute', now(), TimeGenerated) / 60.0, 1)
| project UserName, SessionHostName, DisconnectedSince = TimeGenerated, DisconnectedHours, ResourceId = _ResourceId
''', '__POOL__', hostPoolName), '__THRESHOLD__', string(disconnectedSessionAlertThresholdHours))
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',          operator: 'Include', values: ['*'] }
            { name: 'SessionHostName',   operator: 'Include', values: ['*'] }
            { name: 'DisconnectedHours', operator: 'Include', values: ['*'] }
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
// FSLogix Profile Alerts
// ------------------------------------

// FSLogix profile < 5% free (EventID 34, Warning) - enriched with user and storage account context
// Joins FSLogix warnings with WVDConnections to identify which user's profile is nearly full,
// on which session host, and pointing to which storage account.
resource alertFSLogixProfile5PctFree 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-SpaceLow5pct-${hostPoolName}'
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
          query: replace('''
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
    | where _ResourceId has "__POOL__"
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
''', '__POOL__', hostPoolName)
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
  name: '${alertNamePrefix}-HP-VM-FSLogix-SpaceLow2pct-${hostPoolName}'
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
          query: replace('''
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
    | where _ResourceId has "__POOL__"
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
''', '__POOL__', hostPoolName)
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
// HostPool and VMresourceGroup derived directly from the Event record -- no WVDAgentHealthStatus
// join needed, which was the source of empty fields when that table had no recent records.
resource alertFSLogixNetworkIssue 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-NetworkIssue-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Network Issue (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 43: a session host in ${hostPoolName} cannot reach the FSLogix profile storage. Verify network connectivity between the session hosts and the storage account.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID == 43
| join kind=inner (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | distinct SessionHostName
) on $left.Computer == $right.SessionHostName
| extend
    VMresourceGroup = tostring(split(_ResourceId, '/')[4]),
    HostPool        = "__POOL__"
| project Computer, RenderedDescription, VMresourceGroup, HostPool, ResourceId = _ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',            operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup',     operator: 'Include', values: ['*'] }
            { name: 'HostPool',            operator: 'Include', values: ['*'] }
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

// FSLogix profile disk failed to attach or reattach (EventID 52, 40, or 56)
// FSLogix profile disk failed to attach at logon (EventID 52 or 40)
// Admin log, Error level. UserName is always NT AUTHORITY\SYSTEM in Event table;
// actual user resolved via time-proximate WVDConnections join on Computer == SessionHostName.
// EID 56 (reattach at reconnect) is a separate alert with an event-count threshold to reduce noise.
resource alertFSLogixDiskAttachFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-AttachFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Disk Attach Failed (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 52 or 40: the profile VHD failed to attach at logon on a session host in ${hostPoolName}. The user received a temporary profile. Check FSLogix agent logs on the affected session host, verify the storage account is reachable from the VM, and confirm the VHD is not locked by another session or process.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID in (52, 40)
| extend
    VMresourceGroup = tostring(split(_ResourceId, '/')[4]),
    HostPool        = "__POOL__"
| project EventTime = TimeGenerated, Computer, VMresourceGroup, HostPool, RenderedDescription, ResourceId = _ResourceId
| join kind=leftouter (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | where State == "Connected"
    | project ConnTime = TimeGenerated, UserName, SessionHostName
) on $left.Computer == $right.SessionHostName
| extend TimeDiff = iff(isnotnull(ConnTime), abs(datetime_diff('minute', EventTime, ConnTime)), 9999)
| summarize arg_min(TimeDiff, *) by EventTime, Computer
| project EventTime, Computer, UserName, RenderedDescription, VMresourceGroup, HostPool, ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',            operator: 'Include', values: ['*'] }
            { name: 'UserName',            operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup',     operator: 'Include', values: ['*'] }
            { name: 'HostPool',            operator: 'Include', values: ['*'] }
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

// FSLogix VHD reattach failed during session reconnect (EventID 56)
// EID 56 fires on EACH retry attempt. FSLogix default retry count is 3 (ReAttachCount registry
// value, default interval 10s), so one failed reconnect produces 3 events in ~30 seconds.
// Threshold >= 3 events per session host in the window means at least one complete retry cycle
// was exhausted -- a real problem, not a transient blip.
// Severity 2: the user session already exists; data loss risk is lower than a logon failure.
// If this alert is still noisy, raise the threshold or window to match observed retry behavior.
resource alertFSLogixVhdReattachFailed 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-ReattachFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix VHD Reattach Failed (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 56: a session host in ${hostPoolName} failed to reattach a profile VHD during user reconnect, exhausting all retry attempts (>= 3 events in 15 minutes). The profile path in RenderedDescription identifies the affected user. Check storage account reachability and the FSLogix log on the affected session host.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID == 56
| join kind=inner (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | distinct SessionHostName
) on $left.Computer == $right.SessionHostName
| extend
    VMresourceGroup = tostring(split(_ResourceId, '/')[4]),
    HostPool        = "__POOL__"
| summarize
    EventCount      = count(),
    VMresourceGroup = any(VMresourceGroup),
    HostPool        = any(HostPool),
    ResourceId      = any(_ResourceId)
  by Computer, RenderedDescription
| where EventCount >= 3
| project Computer, RenderedDescription, EventCount, VMresourceGroup, HostPool, ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',            operator: 'Include', values: ['*'] }
            { name: 'EventCount',          operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup',     operator: 'Include', values: ['*'] }
            { name: 'HostPool',            operator: 'Include', values: ['*'] }
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

// FSLogix service disabled (EventID 60)
// EventID 60 fires ONCE when the service transitions to disabled, then stops.
// windowSize PT4H keeps the alert open long enough for operators to respond without
// running all day; autoMitigate resolves it when the condition clears.
// Scoped to this host pool via WVDConnections inner join on Computer == SessionHostName.
resource alertFSLogixServiceDisabled 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-ServiceDisabled-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Required Service Disabled (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 60: a service required by FSLogix is disabled on a session host in ${hostPoolName}. Re-enable the required service immediately.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT4H'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Warning"
| where EventID == 60
| join kind=inner (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | distinct SessionHostName
) on $left.Computer == $right.SessionHostName
| extend
    VMresourceGroup = tostring(split(_ResourceId, '/')[4]),
    HostPool        = "__POOL__"
| project Computer, RenderedDescription, VMresourceGroup, HostPool, ResourceId = _ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',            operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup',     operator: 'Include', values: ['*'] }
            { name: 'HostPool',            operator: 'Include', values: ['*'] }
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

// FSLogix disk compaction failed (EventID 62 or 63)
// Compaction fires at logoff; HostPool and VMresourceGroup derived directly.
resource alertFSLogixDiskCompaction 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-CompactFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Disk Compaction Failed (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 62 or 63: profile disk compaction failed 3 or more times on a session host in ${hostPoolName}. VHD files will continue growing until compaction succeeds. Ensure the session host OS disk has sufficient free space and the profile VHD is not actively in use, then retry compaction.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Admin"
| where EventLevelName == "Error"
| where EventID == 62 or EventID == 63
| join kind=inner (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | distinct SessionHostName
) on $left.Computer == $right.SessionHostName
| extend
    VMresourceGroup = tostring(split(_ResourceId, '/')[4]),
    HostPool        = "__POOL__"
| summarize
    EventCount      = count(),
    VMresourceGroup = any(VMresourceGroup),
    HostPool        = any(HostPool),
    ResourceId      = any(_ResourceId)
  by Computer, RenderedDescription
| where EventCount >= 3
| project Computer, RenderedDescription, EventCount, VMresourceGroup, HostPool, ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',            operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'EventCount',          operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup',     operator: 'Include', values: ['*'] }
            { name: 'HostPool',            operator: 'Include', values: ['*'] }
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

// FSLogix profile disk in use by another VM (EventID 51)
// Event fires in Operational log at Warning level. Computer and UserName are present
// directly on the event record - no WVDConnections join is needed.
// VMresourceGroup is derived from _ResourceId (split on '/'); may be empty when the agent
// does not attach the VM ARM resource ID to Operational events.
resource alertFSLogixDiskInUse 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-DiskInUse-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Profile Disk In Use by Another VM (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 51: a session host in ${hostPoolName} has detected a profile VHD locked by another VM 3 or more times in the last 15 minutes. Check for a stale .lck file on the share, or a session that did not cleanly log off.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
Event
| where EventLog == "Microsoft-FSLogix-Apps/Operational"
| where EventLevelName == "Warning"
| where EventID == 51
| join kind=inner (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | distinct SessionHostName
) on $left.Computer == $right.SessionHostName
| extend
    VMresourceGroup = tostring(split(_ResourceId, '/')[4]),
    HostPool        = "__POOL__"
| summarize
    EventCount      = count(),
    UserName        = any(UserName),
    VMresourceGroup = any(VMresourceGroup),
    HostPool        = any(HostPool),
    ResourceId      = any(_ResourceId)
  by Computer, RenderedDescription
| where EventCount >= 3
| project Computer, UserName, RenderedDescription, EventCount, VMresourceGroup, HostPool, ResourceId
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',            operator: 'Include', values: ['*'] }
            { name: 'UserName',            operator: 'Include', values: ['*'] }
            { name: 'RenderedDescription', operator: 'Include', values: ['*'] }
            { name: 'EventCount',          operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup',     operator: 'Include', values: ['*'] }
            { name: 'HostPool',            operator: 'Include', values: ['*'] }
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

// FSLogix corrupted / temp profile (EventID 28)
// Uses a two-step lookup to correlate the error with a storage account path
// (EventID 28 itself does not include the path, so we find a nearby event that does),
// then joins with WVDConnections to identify the affected user.
resource alertFSLogixCorruptedProfile 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableFslogixAlerts) {
  name: '${alertNamePrefix}-HP-VM-FSLogix-Corrupted-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Corrupted / Temp Profile (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 28 in ${hostPoolName}: a user profile VHD is corrupted or could not be mounted and the user was loaded into a temporary profile. Data written during this session will be lost. Investigate and repair the profile VHD.'
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
          query: replace('''
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
    | where _ResourceId has "__POOL__"
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
''', '__POOL__', hostPoolName)
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
  name: '${alertNamePrefix}-HP-VM-FSLogix-PreCheckFailed-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - FSLogix Compaction Pre-Check Failed (${hostPoolName})'
    description: '${descriptionHeader}FSLogix Event ID 58 or 61 in ${hostPoolName}: VHD disk compaction was aborted before starting, either because the host disk lacks free space for the operation (58) or the VHD is in use (61). Profile VHDs will grow unbounded until compaction can complete.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    scopes: [logAnalyticsWorkspaceResourceId]
    autoMitigate: autoResolveAlert
    criteria: {
      allOf: [
        {
          query: replace('''
let fslogixErrors =
    Event
    | where Source == "Microsoft-FSLogix-Apps"
    | where EventID in (58, 61)
    | extend StorageAccount = extract(@"\\\\([^\\]+\.file\.core\.[^\\]+)", 1, RenderedDescription)
    | project EventTime = TimeGenerated, Computer, StorageAccount, EventID, RenderedDescription;
fslogixErrors
| join kind=inner (
    WVDConnections
    | where _ResourceId has "__POOL__"
    | where State == "Connected"
    | project ConnTime = TimeGenerated, UserName, SessionHostName, ResourceId = _ResourceId
) on $left.Computer == $right.SessionHostName
| extend TimeDiff = abs(datetime_diff('minute', EventTime, ConnTime))
| where TimeDiff <= 30
| summarize arg_min(TimeDiff, *) by EventTime, Computer
| project
    EventTime,
    UserName,
    SessionHostName = Computer,
    StorageAccount,
    EventID,
    RenderedDescription,
    ResourceId
| order by EventTime desc
''', '__POOL__', hostPoolName)
          timeAggregation: 'Count'
          dimensions: [
            { name: 'UserName',        operator: 'Include', values: ['*'] }
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

// Slow session logon - time from connection start to productive desktop > configured threshold (default slowLogonThresholdMinutes minutes)
// Uses WVDCheckpoints ShellReady / RdpShellAppExecuted to measure full logon time
// (includes Windows logon, profile load, GPO processing, startup scripts).
// Fires at Sev 3 as an early warning; repeated occurrences indicate profile bloat, GPO issues,
// or storage latency on the FSLogix share.
resource alertSlowSessionLogon 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableConnectionAlerts) {
  name: '${alertNamePrefix}-HP-Conn-SlowLogon-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Slow Session Logon > ${slowLogonThresholdMinutes} Minutes (${hostPoolName})'
    description: '${descriptionHeader}A user in ${hostPoolName} took more than ${slowLogonThresholdMinutes} minute(s) from connection start to productive desktop. Common causes: FSLogix profile bloat, GPO processing delay, slow storage, or startup scripts. Review FSLogix profile sizes and storage latency.'
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
          query: replace(replace('''
WVDConnections
| where TimeGenerated > ago(30m)
| where _ResourceId has "__POOL__"
| where State == "Started"
| project CorrelationId, UserName, SessionHostName, StartTime = TimeGenerated, ResourceId = _ResourceId
| join kind=inner (
    WVDCheckpoints
    | where _ResourceId has "__POOL__"
    | where Name =~ "ShellReady"
        or (Name =~ "LaunchExecutable" and tostring(Parameters.connectionStage) == "RdpShellAppExecuted")
        or Name =~ "RdpShellAppExecuted"
    | summarize ShellReadyTime = min(TimeGenerated) by CorrelationId
) on CorrelationId
| extend LogonSeconds = datetime_diff('second', ShellReadyTime, StartTime)
| where LogonSeconds > __THRESHOLD__
| project
    StartTime,
    UserName,
    SessionHostName,
    LogonSeconds,
    LogonMinutes = round(LogonSeconds / 60.0, 1),
    ResourceId
| order by LogonSeconds desc
''', '__POOL__', hostPoolName), '__THRESHOLD__', string(slowLogonThresholdMinutes * 60))
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

// AVD Alerts Add-On - VM Alert Rules Module
// Deploys all VM-level alert rules for a host pool's session hosts.
// Includes both ARM metric alerts (CPU, OS disk bandwidth) and KQL Scheduled Query Rules
// (local C: disk space, available memory) — all targeting session host VMs.
//
// In this solution each host pool has its own dedicated VM resource group (1:1).
// Alert rules are named after the host pool and tagged with cm-resource-parent
// pointing to the host pool for Azure Cost Management rollup.
//
// Alert rules:
//   Metric alerts (multi-resource, scoped to the VM resource group):
//     - Percentage CPU > 85%              (Sev 2)
//     - Percentage CPU > 95%              (Sev 1)
//     - OS Disk Bandwidth >= 85%          (Sev 2)
//     - OS Disk Bandwidth >= 95%          (Sev 1)
//   Scheduled query rules (scoped to Log Analytics workspace, filtered by host pool):
//     - Local C: drive free space <= 10%  (Sev 2)
//     - Local C: drive free space <= 5%   (Sev 1)
//     - Available memory < 2 GB           (Sev 2)
//     - Available memory < 1 GB           (Sev 1)

// ========== //
// Parameters //
// ========== //

@description('Required. Resource ID of the resource group containing the session host VMs.')
param vmResourceGroupId string

@description('Required. Resource ID of the Action Group for notifications.')
param actionGroupResourceId string

@description('Optional. Prefix prepended to all alert names.')
param alertNamePrefix string = 'AVD'

@description('Optional. Whether alert rules auto-resolve when the condition clears.')
param autoResolveAlert bool = true

@description('Required. Azure region of the session host VMs (required for multi-resource metric alerts).')
param location string

@description('Required. Resource ID of the Log Analytics Workspace. Used for Scheduled Query Rule scopes.')
param logAnalyticsWorkspaceResourceId string

@description('Optional. When false, CPU alert rules are not deployed.')
param enableCpuAlerts bool = true

@description('Optional. When false, OS disk bandwidth alert rules are not deployed.')
param enableOsDiskAlerts bool = true

@description('Optional. When false, session host local disk free-space alert rules are not deployed.')
param enableLocalDiskAlerts bool = true

@description('Optional. When false, session host VM available memory alert rules are not deployed.')
param enableMemoryAlerts bool = true

@description('Optional. Minutes of Perf data stream age required before memory alerts fire. A VM whose oldest Perf record in the lookback window is newer than this value is treated as still starting up and excluded. Set to 0 to disable.')
@minValue(0)
@maxValue(60)
param memoryAlertStartupExclusionMinutes int = 20

@description('Required. Name of the host pool whose VMs this module monitors. Used in alert rule names.')
param hostPoolName string

@description('Required. Full resource ID of the host pool. Used to set the cm-resource-parent tag on alert rules for Azure Cost Management rollup.')
param hostPoolResourceId string

// ========== //
// Variables  //
// ========== //

var vmRgName          = last(split(vmResourceGroupId, '/'))
var descriptionHeader = 'AVD - Automated Alert\n'

var hostPoolTags = {
  'cm-resource-parent': hostPoolResourceId
}

var metricActions = [
  {
    actionGroupId: actionGroupResourceId
  }
]

// Actions block for Scheduled Query Rules (different schema from metric alerts)
var actions = {
  actionGroups: [actionGroupResourceId]
}

// ========== //
// Resources  //
// ========== //

// CPU > 85% (Sev 2)
resource alertCPU85 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableCpuAlerts) {
  name: '${alertNamePrefix}-VM-CPU-85pct-${hostPoolName}'
  location: 'global'
  tags: hostPoolTags
  properties: {
    description: '${descriptionHeader}Session host CPU usage exceeded 85% average over 15 minutes. Host pool: ${hostPoolName}. VM resource group: ${vmRgName}. Review high-CPU processes and consider adding more session hosts or adjusting the scaling plan.'
    severity: 2
    enabled: true
    scopes: [vmResourceGroupId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'microsoft.compute/virtualmachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricNamespace: 'microsoft.compute/virtualmachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// CPU > 95% (Sev 1)
resource alertCPU95 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableCpuAlerts) {
  name: '${alertNamePrefix}-VM-CPU-95pct-${hostPoolName}'
  location: 'global'
  tags: hostPoolTags
  properties: {
    description: '${descriptionHeader}CRITICAL: Session host CPU usage exceeded 95% average over 15 minutes. Host pool: ${hostPoolName}. VM resource group: ${vmRgName}. Users on this host are likely experiencing severe performance degradation.'
    severity: 1
    enabled: true
    scopes: [vmResourceGroupId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'microsoft.compute/virtualmachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricNamespace: 'microsoft.compute/virtualmachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 95
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// OS Disk Bandwidth >= 85% (Sev 2)
resource alertOSDiskBandwidth85 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableOsDiskAlerts) {
  name: '${alertNamePrefix}-VM-OSDisk-BW85pct-${hostPoolName}'
  location: 'global'
  tags: hostPoolTags
  properties: {
    description: '${descriptionHeader}OS Disk bandwidth consumption on a session host is at or above 85%. Host pool: ${hostPoolName}. VM resource group: ${vmRgName}. The VM is nearing its disk IOPS limit. Consider moving to a larger or premium disk SKU.'
    severity: 2
    enabled: true
    scopes: [vmResourceGroupId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'microsoft.compute/virtualmachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricNamespace: 'microsoft.compute/virtualmachines'
          metricName: 'OS Disk Bandwidth Consumed Percentage'
          operator: 'GreaterThanOrEqual'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'LUN'
              operator: 'Include'
              values: ['*']
            }
          ]
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// OS Disk Bandwidth >= 95% (Sev 1)
resource alertOSDiskBandwidth95 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableOsDiskAlerts) {
  name: '${alertNamePrefix}-VM-OSDisk-BW95pct-${hostPoolName}'
  location: 'global'
  tags: hostPoolTags
  properties: {
    description: '${descriptionHeader}CRITICAL: OS Disk bandwidth on a session host is at or above 95%. Host pool: ${hostPoolName}. VM resource group: ${vmRgName}. Users will experience severe I/O latency. Upgrade disk SKU immediately.'
    severity: 1
    enabled: true
    scopes: [vmResourceGroupId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'microsoft.compute/virtualmachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricNamespace: 'microsoft.compute/virtualmachines'
          metricName: 'OS Disk Bandwidth Consumed Percentage'
          operator: 'GreaterThanOrEqual'
          threshold: 95
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'LUN'
              operator: 'Include'
              values: ['*']
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
// Local Disk Space Alerts (KQL / Perf table)
// ------------------------------------
// Scoped to this host pool via WVDAgentHealthStatus.SessionHostResourceId (VM name parsed from ARM ID)
// joined to Perf._ResourceId (also parsed). Uses LogicalDisk % Free Space collected by AMA.

// Local C: drive free space <= 10% (Sev 2)
resource alertLocalDiskFree10 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableLocalDiskAlerts) {
  name: '${alertNamePrefix}-VM-DiskLow10pct-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - VM Local Disk Space Low - 10pct (${hostPoolName})'
    description: '${descriptionHeader}A session host in ${hostPoolName} has 10% or less free space on the C: drive. Review disk usage and clean up temporary files or expand the OS disk.'
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
let hostPoolVMs =
    WVDAgentHealthStatus
    | where TimeGenerated > ago(15m)
    | where _ResourceId has "${hostPoolName}"
    | parse SessionHostResourceId with "/subscriptions/" sub "/resourceGroups/" rg "/providers/Microsoft.Compute/virtualMachines/" vmName
    | extend vmName = tolower(vmName)
    | summarize by vmName;
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName !contains "D:" and InstanceName !contains "_Total"
| where CounterValue <= 10.00
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" VMresourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName = tolower(ComputerName)
| where ComputerName in (hostPoolVMs)
| summarize arg_max(TimeGenerated, *) by ComputerName
| extend HostPool = "${hostPoolName}"
| project ComputerName, CounterValue, VMresourceGroup, HostPool, ResourceId = _ResourceId
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName',    operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool',        operator: 'Include', values: ['*'] }
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

// Local C: drive free space <= 5% (Sev 1)
resource alertLocalDiskFree5 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableLocalDiskAlerts) {
  name: '${alertNamePrefix}-VM-DiskLow5pct-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - VM Local Disk Space Low - 5pct (${hostPoolName})'
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
let hostPoolVMs =
    WVDAgentHealthStatus
    | where TimeGenerated > ago(15m)
    | where _ResourceId has "${hostPoolName}"
    | parse SessionHostResourceId with "/subscriptions/" sub "/resourceGroups/" rg "/providers/Microsoft.Compute/virtualMachines/" vmName
    | extend vmName = tolower(vmName)
    | summarize by vmName;
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName !contains "D:" and InstanceName !contains "_Total"
| where CounterValue <= 5.00
| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" VMresourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
| extend ComputerName = tolower(ComputerName)
| where ComputerName in (hostPoolVMs)
| summarize arg_max(TimeGenerated, *) by ComputerName
| extend HostPool = "${hostPoolName}"
| project ComputerName, CounterValue, VMresourceGroup, HostPool, ResourceId = _ResourceId
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'ComputerName',    operator: 'Include', values: ['*'] }
            { name: 'VMresourceGroup', operator: 'Include', values: ['*'] }
            { name: 'HostPool',        operator: 'Include', values: ['*'] }
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
// VM Memory Alerts (KQL / Perf table)
// ------------------------------------
// Uses Perf data collected by the AVD Insights AMA Data Collection Rule (Available MBytes every 30s).
// Scoped to this host pool's VMs via WVDAgentHealthStatus.SessionHostResourceId joined to Perf._ResourceId
// (both are VM ARM resource IDs - no computer name parsing required).
// Startup exclusion: a VM is excluded when the oldest Perf record in the 1-hour lookback window
// arrived less than memoryAlertStartupExclusionMinutes ago. Because both the exclusion signal and the
// memory data come from the same table and ingestion pipeline, there is no differential ingestion
// lag that could cause a newly started VM to slip through the exclusion.

// Available memory < 2 GB (Sev 2)
resource alertMemoryLow2GB 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableMemoryAlerts) {
  name: '${alertNamePrefix}-VM-Memory-Low2gb-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Available Memory < 2 GB (${hostPoolName})'
    description: '${descriptionHeader}Available memory on a session host in ${hostPoolName} dropped below 2 GB average over 15 minutes. Users may experience application slowdowns. Review memory usage and consider adding more session hosts or adjusting the scaling plan. VMs booting within the last ${memoryAlertStartupExclusionMinutes} minutes are excluded.'
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
          query: '''let startupExclusionMins = ${memoryAlertStartupExclusionMinutes};
let hostPoolVmIds =
    WVDAgentHealthStatus
    | where TimeGenerated > ago(15m)
    | where _ResourceId has "${hostPoolName}"
    | summarize by vmResourceId = tolower(SessionHostResourceId);
let perfData =
    Perf
    | where TimeGenerated > ago(1h)
    | where ObjectName == "Memory" and CounterName == "Available MBytes"
    | extend vmResourceId = tolower(_ResourceId)
    | where vmResourceId in (hostPoolVmIds);
let perfAge =
    perfData
    | summarize FirstPerf = min(TimeGenerated) by vmResourceId;
perfData
| where TimeGenerated > ago(15m)
| summarize AvgMemMB = avg(CounterValue), ResourceId = any(_ResourceId), Computer = any(Computer) by vmResourceId
| join kind=inner perfAge on vmResourceId
| where FirstPerf < ago(startupExclusionMins * 1m)
| where AvgMemMB <= 2048
| extend HostPool = "${hostPoolName}"
| project Computer, AvgMemMB, HostPool, ResourceId
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',  operator: 'Include', values: ['*'] }
            { name: 'AvgMemMB', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
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

// Available memory < 1 GB (Sev 1)
resource alertMemoryLow1GB 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableMemoryAlerts) {
  name: '${alertNamePrefix}-VM-Memory-Low1gb-${hostPoolName}'
  location: location
  tags: hostPoolTags
  properties: {
    displayName: '${alertNamePrefix} - Available Memory < 1 GB (${hostPoolName})'
    description: '${descriptionHeader}CRITICAL: Available memory on a session host in ${hostPoolName} dropped below 1 GB average over 15 minutes. Users will likely experience application crashes and severe performance issues. Add more session hosts immediately. VMs booting within the last ${memoryAlertStartupExclusionMinutes} minutes are excluded.'
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
          query: '''let startupExclusionMins = ${memoryAlertStartupExclusionMinutes};
let hostPoolVmIds =
    WVDAgentHealthStatus
    | where TimeGenerated > ago(15m)
    | where _ResourceId has "${hostPoolName}"
    | summarize by vmResourceId = tolower(SessionHostResourceId);
let perfData =
    Perf
    | where TimeGenerated > ago(1h)
    | where ObjectName == "Memory" and CounterName == "Available MBytes"
    | extend vmResourceId = tolower(_ResourceId)
    | where vmResourceId in (hostPoolVmIds);
let perfAge =
    perfData
    | summarize FirstPerf = min(TimeGenerated) by vmResourceId;
perfData
| where TimeGenerated > ago(15m)
| summarize AvgMemMB = avg(CounterValue), ResourceId = any(_ResourceId), Computer = any(Computer) by vmResourceId
| join kind=inner perfAge on vmResourceId
| where FirstPerf < ago(startupExclusionMins * 1m)
| where AvgMemMB <= 1024
| extend HostPool = "${hostPoolName}"
| project Computer, AvgMemMB, HostPool, ResourceId
'''
          timeAggregation: 'Count'
          dimensions: [
            { name: 'Computer',  operator: 'Include', values: ['*'] }
            { name: 'AvgMemMB', operator: 'Include', values: ['*'] }
            { name: 'HostPool', operator: 'Include', values: ['*'] }
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

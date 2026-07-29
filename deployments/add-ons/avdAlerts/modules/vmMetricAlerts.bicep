// AVD Alerts Add-On - VM Metric Alert Rules Module
// Deploys multi-resource metric alert rules scoped to a VM resource group,
// covering all session host VMs in that resource group.
//
// In this solution each host pool has its own dedicated VM resource group (1:1).
// Alert rules are named after the VM resource group and tagged with cm-resource-parent
// pointing to the host pool for Azure Cost Management rollup.
//
// Alert rules:
//   - Percentage CPU > 85%            (Sev 2)
//   - Percentage CPU > 95%            (Sev 1)
//   - Available Memory Bytes <= 2 GB  (Sev 2)
//   - Available Memory Bytes <= 1 GB  (Sev 1)
//   - OS Disk Bandwidth >= 85%        (Sev 2)
//   - OS Disk Bandwidth >= 95%        (Sev 1)

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

@description('Optional. When false, CPU alert rules are not deployed.')
param enableCpuAlerts bool = true

@description('Optional. When false, available memory alert rules are not deployed.')
param enableMemoryAlerts bool = true

@description('Optional. When false, OS disk bandwidth alert rules are not deployed.')
param enableOsDiskAlerts bool = true

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

// Available Memory <= 2 GB (Sev 2)  - 2 GB = 2147483648 bytes
resource alertMemory2GB 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableMemoryAlerts) {
  name: '${alertNamePrefix}-VM-Memory-Low2gb-${hostPoolName}'
  location: 'global'
  tags: hostPoolTags
  properties: {
    description: '${descriptionHeader}Available memory on a session host dropped below 2 GB. Host pool: ${hostPoolName}. VM resource group: ${vmRgName}. Users may experience application slowdowns. Review memory usage and consider adding more session hosts.'
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
          metricName: 'Available Memory Bytes'
          operator: 'LessThanOrEqual'
          threshold: 2147483648
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: autoResolveAlert
    actions: metricActions
  }
}

// Available Memory <= 1 GB (Sev 1)  - 1 GB = 1073741824 bytes
resource alertMemory1GB 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableMemoryAlerts) {
  name: '${alertNamePrefix}-VM-Memory-Low1gb-${hostPoolName}'
  location: 'global'
  tags: hostPoolTags
  properties: {
    description: '${descriptionHeader}CRITICAL: Available memory on a session host dropped below 1 GB. Host pool: ${hostPoolName}. VM resource group: ${vmRgName}. Users will likely experience application crashes and severe performance issues.'
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
          metricName: 'Available Memory Bytes'
          operator: 'LessThanOrEqual'
          threshold: 1073741824
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

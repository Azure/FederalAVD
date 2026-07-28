// AVD Alerts Add-On - VM Metric Alert Rules Module
// Deploys multi-resource metric alert rules scoped to a VM resource group,
// covering all session host VMs in that resource group for a given host pool.
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

@description('Required. Name of the host pool (used in alert names and descriptions).')
param hostPoolName string

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

// ========== //
// Variables  //
// ========== //

var descriptionHeader = 'FederalAVD - Automated Alert\n'

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
  name: '${alertNamePrefix}-HP-VM-HighCPU85Prcnt-${hostPoolName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Session host CPU usage exceeded 85% average over 15 minutes in ${hostPoolName}. Review high-CPU processes and consider adding more session hosts or adjusting the scaling plan.'
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
  name: '${alertNamePrefix}-HP-VM-HighCPU95Prcnt-${hostPoolName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}CRITICAL: Session host CPU usage exceeded 95% average over 15 minutes in ${hostPoolName}. Users on this host are likely experiencing severe performance degradation.'
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
  name: '${alertNamePrefix}-HP-VM-AvailMemLess2GB-${hostPoolName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Available memory on a session host in ${hostPoolName} dropped below 2 GB. Users on this host may experience application slowdowns. Review memory usage and consider adding more session hosts.'
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
  name: '${alertNamePrefix}-HP-VM-AvailMemLess1GB-${hostPoolName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}CRITICAL: Available memory on a session host in ${hostPoolName} dropped below 1 GB. Users will likely experience application crashes and severe performance issues.'
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
  name: '${alertNamePrefix}-HP-VM-OSDiskBW85Prcnt-${hostPoolName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}OS Disk bandwidth consumption on a session host in ${hostPoolName} is at or above 85%. The VM is nearing its disk IOPS limit. Consider moving to a larger or premium disk SKU.'
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
  name: '${alertNamePrefix}-HP-VM-OSDiskBW95Prcnt-${hostPoolName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}CRITICAL: OS Disk bandwidth on a session host in ${hostPoolName} is at or above 95%. Users will experience severe I/O latency. Upgrade disk SKU immediately.'
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

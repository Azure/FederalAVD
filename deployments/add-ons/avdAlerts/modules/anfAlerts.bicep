// AVD Alerts Add-On - Azure NetApp Files Volume Alert Rules Module
// Deploys metric alert rules for an ANF volume used for FSLogix profile storage.
//
// Alert rules:
//   - VolumeConsumedSizePercentage >= 85%  (Sev 2)
//   - VolumeConsumedSizePercentage >= 95%  (Sev 1)

// ========== //
// Parameters //
// ========== //

@description('Required. Resource ID of the Azure NetApp Files volume to monitor.')
param anfVolumeResourceId string

@description('Required. Resource ID of the Action Group for notifications.')
param actionGroupResourceId string

@description('Optional. Prefix prepended to all alert names.')
param alertNamePrefix string = 'AVD'

@description('Optional. Whether alert rules auto-resolve when the condition clears.')
param autoResolveAlert bool = true

@description('Optional. When false, ANF volume capacity alert rules are not deployed.')
param enableAnfCapacityAlerts bool = true

// ========== //
// Variables  //
// ========== //

var volumeName       = last(split(anfVolumeResourceId, '/'))
var descriptionHeader = 'AVD - Automated Alert\n'

var metricActions = [
  {
    actionGroupId: actionGroupResourceId
  }
]

// ========== //
// Resources  //
// ========== //

// ANF volume consumed >= 85% (Sev 2)
resource alertAnfVolume85 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableAnfCapacityAlerts) {
  name: '${alertNamePrefix}-ANF-Capacity-85pct-${volumeName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}Azure NetApp Files volume ${volumeName} has consumed 85% or more of its provisioned capacity. Expand the volume before it fills completely to prevent profile load failures.'
    severity: 2
    enabled: true
    scopes: [anfVolumeResourceId]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    targetResourceType: 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricNamespace: 'microsoft.netapp/netappaccounts/capacitypools/volumes'
          metricName: 'VolumeConsumedSizePercentage'
          operator: 'GreaterThanOrEqual'
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

// ANF volume consumed >= 95% (Sev 1)
resource alertAnfVolume95 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableAnfCapacityAlerts) {
  name: '${alertNamePrefix}-ANF-Capacity-95pct-${volumeName}'
  location: 'global'
  properties: {
    description: '${descriptionHeader}CRITICAL: Azure NetApp Files volume ${volumeName} has consumed 95% or more of its provisioned capacity. Expand the volume immediately - new FSLogix profile mounts will fail when the volume is full.'
    severity: 1
    enabled: true
    scopes: [anfVolumeResourceId]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    targetResourceType: 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Metric1'
          metricNamespace: 'microsoft.netapp/netappaccounts/capacitypools/volumes'
          metricName: 'VolumeConsumedSizePercentage'
          operator: 'GreaterThanOrEqual'
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

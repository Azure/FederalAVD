@sys.description('Required. Name of the scaling plan.')
@minLength(3)
param name string

@sys.description('Optional. Location for all resources.')
param location string = resourceGroup().location

@sys.description('Optional. Friendly Name of the scaling plan.')
param friendlyName string = name

@sys.description('Optional. Description of the scaling plan.')
param description string = name

@sys.description('Optional. Timezone to be used for the scaling plan.')
param timeZone string

@sys.description('Optional. An array of references to hostpools.')
param hostPoolResourceId string

@sys.description('Optional. The type of hostpool where this scaling plan should be applied.')
param hostPoolType string

@sys.description('Optional. Provide a tag to be used for hosts that should not be affected by the scaling plan.')
param exclusionTag string = ''

@sys.description('Optional. The schedules related to this scaling plan. If no value is provided a default schedule will be provided.')
param schedules array = [
  {
    rampUpStartTime: {
      hour: 7
      minute: 0
    }
    peakStartTime: {
      hour: 8
      minute: 0
    }
    rampDownStartTime: {
      hour: 17
      minute: 0
    }
    offPeakStartTime: {
      hour: 20
      minute: 0
    }
    name: 'weekdays_schedule'
    daysOfWeek: [
      'Monday'
      'Tuesday'
      'Wednesday'
      'Thursday'
      'Friday'
    ]
    rampUpLoadBalancingAlgorithm: 'DepthFirst'
    rampUpMinimumHostsPct: 20
    rampUpCapacityThresholdPct: 60
    peakLoadBalancingAlgorithm: 'DepthFirst'
    rampDownLoadBalancingAlgorithm: 'DepthFirst'
    rampDownMinimumHostsPct: 10
    rampDownCapacityThresholdPct: 90
    rampDownForceLogoffUsers: true
    rampDownWaitTimeMinutes: 30
    rampDownNotificationMessage: 'You will be logged off in 30 min. Make sure to save your work.'
    rampDownStopHostsWhen: 'ZeroSessions'
    offPeakLoadBalancingAlgorithm: 'DepthFirst'
  }
]

@sys.description('Optional. Tags of the resource.')
param tags object = {}

@sys.description('Optional. Resource ID of the diagnostic log analytics workspace.')
param diagnosticWorkspaceId string = ''

@sys.description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource.')
@allowed([
  'allLogs'
  'Autoscale'
])
param diagnosticLogCategoriesToEnable array = [
  'allLogs'
]

var diagnosticsLogsSpecified = [for category in filter(diagnosticLogCategoriesToEnable, item => item != 'allLogs'): {
  category: category
  enabled: true
}]

var diagnosticsLogs = contains(diagnosticLogCategoriesToEnable, 'allLogs') ? [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
] : diagnosticsLogsSpecified

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = {
  name: name
  location: location
  tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
  properties: {
    friendlyName: friendlyName
    timeZone: timeZone
    hostPoolType: hostPoolType
    exclusionTag: exclusionTag
    schedules: schedules
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolResourceId
        scalingPlanEnabled: true
      }
    ]
    description: description
  }
}

resource scalingplan_diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(diagnosticWorkspaceId)) {
  name: '${scalingPlan.name}-diagnosticsetting'
  properties: {
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    logs: diagnosticsLogs
  }
  scope: scalingPlan
}

@sys.description('The resource ID of the AVD scaling plan.')
output resourceId string = scalingPlan.id

@sys.description('The resource group the AVD scaling plan was deployed into.')
output resourceGroupName string = resourceGroup().name

@sys.description('The name of the AVD scaling plan.')
output name string = scalingPlan.name

@sys.description('The location the resource was deployed into.')
output location string = scalingPlan.location

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

@sys.description('Required. The schedules related to this scaling plan. Schedules must be pre-built for the appropriate host pool type (Personal or Pooled).')
param schedules array

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

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2023-09-05' = {
  name: name
  location: location
  tags: tags[?'Microsoft.DesktopVirtualization/scalingPlans'] ?? {}
  properties: {
    friendlyName: friendlyName
    timeZone: timeZone
    hostPoolType: hostPoolType
    exclusionTag: exclusionTag
    schedules: []
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolResourceId
        scalingPlanEnabled: true
      }
    ]
    description: description
  }
}

resource schedules_Pooled 'Microsoft.DesktopVirtualization/scalingPlans/pooledSchedules@2023-09-05' = [for i in range(0, length(schedules)): if (hostPoolType == 'Pooled') {
  name: i == 0 ? 'Weekdays' : 'Weekends'
  parent: scalingPlan
  properties: schedules[i]
  dependsOn: [
    scalingPlan
  ]
}]

resource schedule_Personal 'Microsoft.DesktopVirtualization/scalingPlans/personalSchedules@2023-09-05' = [for i in range(0, length(schedules)): if (hostPoolType == 'Personal') {
  name: i == 0 ? 'Weekdays' : 'Weekends'
  parent: scalingPlan
  properties: schedules[i]
  dependsOn: [
    scalingPlan
  ]
}]

resource scalingplan_diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(diagnosticWorkspaceId)) {
  name: '${scalingPlan.name}-diagnosticsetting'
  properties: {
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    logs: diagnosticsLogs
  }
  dependsOn: [
    schedule_Personal
    schedules_Pooled
  ]
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

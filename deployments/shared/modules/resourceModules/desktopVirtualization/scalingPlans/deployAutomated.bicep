type scalingTimeType = {
  hour: int
  minute: int
}

type dynamicScalingScheduleType = {
  name: string
  daysOfWeek: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')[]
  rampUpStartTime: scalingTimeType
  rampUpLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampUpMinimumHostsPct: int
  rampUpCapacityThresholdPct: int
  rampUpMinimumHostPoolSize: int
  rampUpMaximumHostPoolSize: int
  peakStartTime: scalingTimeType
  peakLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampDownStartTime: scalingTimeType
  rampDownLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampDownMinimumHostsPct: int
  rampDownCapacityThresholdPct: int
  rampDownMinimumHostPoolSize: int
  rampDownMaximumHostPoolSize: int
  rampDownForceLogoffUsers: bool
  rampDownWaitTimeMinutes: int
  rampDownNotificationMessage: string
  rampDownStopHostsWhen: 'ZeroSessions' | 'ZeroActiveSessions'
  offPeakStartTime: scalingTimeType
  offPeakLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
}

param name string
param location string = resourceGroup().location
param tags object = {}
param timeZone string
param exclusionTag string
param hostPoolResourceId string
param scalingPlanEnabled bool = true
param schedules dynamicScalingScheduleType[]

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2025-11-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    timeZone: timeZone
    exclusionTag: exclusionTag
    hostPoolType: 'Pooled'
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolResourceId
        scalingPlanEnabled: scalingPlanEnabled
      }
    ]
  }
}

module pooledSchedules 'pooledSchedules/deploy.bicep' = if (!empty(schedules)) {
  name: 'PooledSchedules-${uniqueString(name, resourceGroup().id)}'
  params: {
    scalingPlanName: scalingPlan.name
    schedules: schedules
  }
}

output resourceId string = scalingPlan.id
output scheduleResourceIds array = !empty(schedules) ? pooledSchedules!.outputs.scheduleResourceIds : []

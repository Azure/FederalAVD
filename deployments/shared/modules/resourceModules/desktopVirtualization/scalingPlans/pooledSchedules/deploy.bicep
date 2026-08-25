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

param scalingPlanName string
param schedules dynamicScalingScheduleType[]

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2025-11-01-preview' existing = {
  name: scalingPlanName
}

resource pooledSchedules 'Microsoft.DesktopVirtualization/scalingPlans/pooledSchedules@2025-11-01-preview' = [for schedule in schedules: {
  parent: scalingPlan
  name: schedule.name
  properties: {
    daysOfWeek: schedule.daysOfWeek
    scalingMethod: 'CreateDeletePowerManage'
    createDelete: {
      rampUpMinimumHostPoolSize: schedule.rampUpMinimumHostPoolSize
      rampUpMaximumHostPoolSize: schedule.rampUpMaximumHostPoolSize
      rampDownMinimumHostPoolSize: schedule.rampDownMinimumHostPoolSize
      rampDownMaximumHostPoolSize: schedule.rampDownMaximumHostPoolSize
    }
    rampUpStartTime: schedule.rampUpStartTime
    rampUpLoadBalancingAlgorithm: schedule.rampUpLoadBalancingAlgorithm
    rampUpMinimumHostsPct: schedule.rampUpMinimumHostsPct
    rampUpCapacityThresholdPct: schedule.rampUpCapacityThresholdPct
    peakStartTime: schedule.peakStartTime
    peakLoadBalancingAlgorithm: schedule.peakLoadBalancingAlgorithm
    rampDownStartTime: schedule.rampDownStartTime
    rampDownLoadBalancingAlgorithm: schedule.rampDownLoadBalancingAlgorithm
    rampDownMinimumHostsPct: schedule.rampDownMinimumHostsPct
    rampDownCapacityThresholdPct: schedule.rampDownCapacityThresholdPct
    rampDownForceLogoffUsers: schedule.rampDownForceLogoffUsers
    rampDownWaitTimeMinutes: schedule.rampDownWaitTimeMinutes
    rampDownNotificationMessage: schedule.rampDownNotificationMessage
    rampDownStopHostsWhen: schedule.rampDownStopHostsWhen
    offPeakStartTime: schedule.offPeakStartTime
    offPeakLoadBalancingAlgorithm: schedule.offPeakLoadBalancingAlgorithm
  }
}]

output scheduleResourceIds array = map(pooledSchedules, schedule => schedule.id)

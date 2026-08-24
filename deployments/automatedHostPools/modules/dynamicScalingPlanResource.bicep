type scalingTimeType = {
  hour: int
  minute: int
}

type dynamicScalingScheduleType = {
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
param scheduleName string
param schedule dynamicScalingScheduleType

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
        scalingPlanEnabled: true
      }
    ]
  }
}

resource pooledSchedule 'Microsoft.DesktopVirtualization/scalingPlans/pooledSchedules@2025-11-01-preview' = {
  parent: scalingPlan
  name: scheduleName
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
}

output resourceId string = scalingPlan.id
output scheduleResourceId string = pooledSchedule.id

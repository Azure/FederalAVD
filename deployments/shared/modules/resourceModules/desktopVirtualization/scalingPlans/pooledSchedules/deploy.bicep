import { dynamicScalingScheduleType } from '../../../types/scalingTypes.bicep'

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

output scheduleResourceIds string[] = map(pooledSchedules, schedule => schedule.id)

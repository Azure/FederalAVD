metadata name = 'Dynamic pooled scaling schedules'
metadata description = 'Deploys create-delete-power-management schedules under an existing scaling plan in the deployment resource group; returns schedule IDs in input order.'

import { dynamicScalingScheduleType } from '../../../types/scalingTypes.bicep'

@description('Required. Name of the existing parent scaling plan in the deployment resource group.')
param scalingPlanName string
@description('Required. Dynamic pooled schedules defining phase times, capacity thresholds and minimum/maximum host counts; an empty array deploys no schedules.')
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

@description('Array of deployed pooled schedule resource IDs in input order; empty when no schedules are supplied.')
output scheduleResourceIds string[] = map(pooledSchedules, schedule => schedule.id)

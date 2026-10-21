metadata name = 'AVD autoscale input types'
metadata description = 'Exports host pool references, days, times and pooled, personal or dynamic schedule shapes for AVD scaling modules; does not create scaling plans.'

// Shared type definitions for Azure Virtual Desktop scaling plans.

@export()
@description('Supported day-of-week names for an AVD scaling schedule.')
type scalingDayType = 'Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday'

@export()
@description('Hour and minute of a schedule phase in the scaling plan time zone.')
type scalingTimeType = {
  hour: int
  minute: int
}

@export()
@description('Existing host pool resource ID and whether the scaling plan is enabled for that host pool.')
type scalingHostPoolReferenceType = {
  hostPoolArmPath: string
  scalingPlanEnabled: bool
}

@export()
@description('Pooled host schedule with daily phases, load balancing, capacity thresholds and ramp-down session handling.')
type pooledScalingScheduleType = {
  name: string
  daysOfWeek: scalingDayType[]
  rampUpStartTime: scalingTimeType
  rampUpLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampUpMinimumHostsPct: int
  rampUpCapacityThresholdPct: int
  peakStartTime: scalingTimeType
  peakLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampDownStartTime: scalingTimeType
  rampDownLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
  rampDownMinimumHostsPct: int
  rampDownCapacityThresholdPct: int
  rampDownForceLogoffUsers: bool
  rampDownWaitTimeMinutes: int
  rampDownNotificationMessage: string?
  rampDownStopHostsWhen: 'ZeroSessions' | 'ZeroActiveSessions'
  offPeakStartTime: scalingTimeType
  offPeakLoadBalancingAlgorithm: 'BreadthFirst' | 'DepthFirst'
}

@export()
@description('Personal host schedule with daily phases, start-on-connect behavior and disconnect or logoff actions.')
type personalScalingScheduleType = {
  name: string
  daysOfWeek: scalingDayType[]
  rampUpStartTime: scalingTimeType
  rampUpAutoStartHosts: 'None' | 'WithAssignedUser' | 'All'
  rampUpStartVMOnConnect: 'Enable' | 'Disable'
  rampUpMinutesToWaitOnDisconnect: int
  rampUpActionOnDisconnect: 'None' | 'Deallocate' | 'Hibernate'
  rampUpMinutesToWaitOnLogoff: int
  rampUpActionOnLogoff: 'None' | 'Deallocate' | 'Hibernate'
  peakStartTime: scalingTimeType
  peakStartVMOnConnect: 'Enable' | 'Disable'
  peakMinutesToWaitOnDisconnect: int
  peakActionOnDisconnect: 'None' | 'Deallocate' | 'Hibernate'
  peakMinutesToWaitOnLogoff: int
  peakActionOnLogoff: 'None' | 'Deallocate' | 'Hibernate'
  rampDownStartTime: scalingTimeType
  rampDownStartVMOnConnect: 'Enable' | 'Disable'
  rampDownMinutesToWaitOnDisconnect: int
  rampDownActionOnDisconnect: 'None' | 'Deallocate' | 'Hibernate'
  rampDownMinutesToWaitOnLogoff: int
  rampDownActionOnLogoff: 'None' | 'Deallocate' | 'Hibernate'
  offPeakStartTime: scalingTimeType
  offPeakStartVMOnConnect: 'Enable' | 'Disable'
  offPeakMinutesToWaitOnDisconnect: int
  offPeakActionOnDisconnect: 'None' | 'Deallocate' | 'Hibernate'
  offPeakMinutesToWaitOnLogoff: int
  offPeakActionOnLogoff: 'None' | 'Deallocate' | 'Hibernate'
}

@export()
@description('Pooled create-delete-power-management schedule with phase-specific host count bounds and capacity settings.')
type dynamicScalingScheduleType = {
  name: string
  daysOfWeek: scalingDayType[]
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

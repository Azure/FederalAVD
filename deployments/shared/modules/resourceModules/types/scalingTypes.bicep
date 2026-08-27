// Shared type definitions for Azure Virtual Desktop scaling plans.

@export()
type scalingDayType = 'Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday'

@export()
type scalingTimeType = {
  hour: int
  minute: int
}

@export()
type scalingHostPoolReferenceType = {
  hostPoolArmPath: string
  scalingPlanEnabled: bool
}

@export()
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

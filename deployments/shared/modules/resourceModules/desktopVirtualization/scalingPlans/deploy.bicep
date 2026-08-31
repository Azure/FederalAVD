import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'
import { personalScalingScheduleType, pooledScalingScheduleType, scalingHostPoolReferenceType } from '../../types/scalingTypes.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

param timeZone string = 'Eastern Standard Time'

@description('Tag name used to exclude session hosts from scaling plan.')
param exclusionTag string = 'ScalingPlanExclusion'

@description('Host pool references for this scaling plan.')
param hostPoolReferences scalingHostPoolReferenceType[] = []

@allowed([
  'Pooled'
  'Personal'
])
@description('Host pool type for this scaling plan.')
param hostPoolType string = 'Pooled'

@description('Pooled host pool scaling schedules.')
param pooledSchedules pooledScalingScheduleType[] = []

@description('Personal host pool scaling schedules.')
param personalSchedules personalScalingScheduleType[] = []

param diagnosticSettings diagnosticSettingsType?

resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2023-09-05' = {
  name: name
  location: location
  tags: tags
  properties: {
    timeZone: timeZone
    exclusionTag: exclusionTag
    hostPoolType: hostPoolType
    hostPoolReferences: hostPoolReferences
    schedules: hostPoolType == 'Pooled' ? pooledSchedules : []
  }
}

resource personalScheduleResources 'Microsoft.DesktopVirtualization/scalingPlans/personalSchedules@2023-09-05' = [for schedule in personalSchedules: if (hostPoolType == 'Personal') {
  parent: scalingPlan
  name: schedule.name
  properties: {
    daysOfWeek: schedule.daysOfWeek
    rampUpStartTime: schedule.rampUpStartTime
    rampUpAutoStartHosts: schedule.rampUpAutoStartHosts
    rampUpStartVMOnConnect: schedule.rampUpStartVMOnConnect
    rampUpMinutesToWaitOnDisconnect: schedule.rampUpMinutesToWaitOnDisconnect
    rampUpActionOnDisconnect: schedule.rampUpActionOnDisconnect
    rampUpMinutesToWaitOnLogoff: schedule.rampUpMinutesToWaitOnLogoff
    rampUpActionOnLogoff: schedule.rampUpActionOnLogoff
    peakStartTime: schedule.peakStartTime
    peakStartVMOnConnect: schedule.peakStartVMOnConnect
    peakMinutesToWaitOnDisconnect: schedule.peakMinutesToWaitOnDisconnect
    peakActionOnDisconnect: schedule.peakActionOnDisconnect
    peakMinutesToWaitOnLogoff: schedule.peakMinutesToWaitOnLogoff
    peakActionOnLogoff: schedule.peakActionOnLogoff
    rampDownStartTime: schedule.rampDownStartTime
    rampDownStartVMOnConnect: schedule.rampDownStartVMOnConnect
    rampDownMinutesToWaitOnDisconnect: schedule.rampDownMinutesToWaitOnDisconnect
    rampDownActionOnDisconnect: schedule.rampDownActionOnDisconnect
    rampDownMinutesToWaitOnLogoff: schedule.rampDownMinutesToWaitOnLogoff
    rampDownActionOnLogoff: schedule.rampDownActionOnLogoff
    offPeakStartTime: schedule.offPeakStartTime
    offPeakStartVMOnConnect: schedule.offPeakStartVMOnConnect
    offPeakMinutesToWaitOnDisconnect: schedule.offPeakMinutesToWaitOnDisconnect
    offPeakActionOnDisconnect: schedule.offPeakActionOnDisconnect
    offPeakMinutesToWaitOnLogoff: schedule.offPeakMinutesToWaitOnLogoff
    offPeakActionOnLogoff: schedule.offPeakActionOnLogoff
  }
}]

var diagTargetNames = filter([
  !empty(diagnosticSettings.?workspaceId ?? '') ? last(split(diagnosticSettings.?workspaceId!, '/')) : ''
  !empty(diagnosticSettings.?storageAccountId ?? '') ? last(split(diagnosticSettings.?storageAccountId!, '/')) : ''
  !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? '')
    ? (!empty(diagnosticSettings.?eventHubName ?? '') ? diagnosticSettings!.eventHubName! : split(diagnosticSettings.?eventHubAuthorizationRuleId!, '/')[8])
    : ''
], t => !empty(t))

var diagnosticSettingName = !empty(diagnosticSettings.?name ?? '')
  ? diagnosticSettings!.name!
  : length(diagTargetNames) > 1
      ? 'diag-${uniqueString(join(diagTargetNames, '-'))}'
      : length(diagTargetNames) == 1
          ? 'diag-${diagTargetNames[0]}'
          : 'diagnostics'

resource diagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettings != null && (!empty(diagnosticSettings.?workspaceId ?? '') || !empty(diagnosticSettings.?storageAccountId ?? '') || !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? ''))) {
  scope: scalingPlan
  name: diagnosticSettingName
  properties: {
    workspaceId: diagnosticSettings.?workspaceId
    storageAccountId: diagnosticSettings.?storageAccountId
    eventHubAuthorizationRuleId: diagnosticSettings.?eventHubAuthorizationRuleId
    eventHubName: diagnosticSettings.?eventHubName
    logs: diagnosticSettings.?logCategories ?? [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

output resourceId string = scalingPlan.id
output name string = scalingPlan.name

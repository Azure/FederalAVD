targetScope = 'subscription'

@description('Resource ID of the existing Session Host Replacer Function App.')
param functionAppResourceId string

@description('Configured Compute Gallery image definition resource ID. Empty for Marketplace images.')
param approvedImageDefinitionResourceId string = ''

@description('Exact Compute Gallery image version approved for this maintenance operation.')
@minLength(1)
param approvedImageVersion string

@description('Maintenance start time in UTC using ISO 8601 format, for example 2026-04-18T22:00:00Z.')
param scheduledDateTimeUtc string

@minValue(30)
@maxValue(1440)
@description('Maximum maintenance window duration in minutes.')
param windowDurationMinutes int = 240

@minValue(1)
@maxValue(1000)
@description('Maximum number of session-host VMs removed in one maintenance batch.')
param maxVmsRemoved int = 1

@minValue(0)
@maxValue(60)
@description('Minutes between notifying connected users and forcing sign-out.')
param logOffDelayMinutes int = 15

@minLength(1)
@maxLength(260)
@description('Message sent to connected users before forced sign-out.')
param logOffMessage string = 'Scheduled maintenance is replacing this session host. Save your work and sign out before the maintenance countdown ends.'

@description('Authorization to forcibly sign out remaining users after the notification delay.')
param forceSignOut bool

@description('Authorization to reduce the host pool to zero available session hosts during maintenance.')
param allowFullPoolOutage bool

@description('Confirmation that no shutdown-retained rollback VMs exist for this replacer.')
param confirmNoShutdownRetention bool

@description('Replace a populated maintenance request. Use only after reviewing its status.')
param replaceExistingRequest bool = false

@description('Unique maintenance request identifier.')
param requestId string = newGuid()

@description('Deployment time used to reject maintenance schedules that are already in the past.')
param deploymentTimeUtc string = utcNow()

var functionAppResourceIdParts = split(functionAppResourceId, '/')
var functionAppSubscriptionId = functionAppResourceIdParts[2]
var functionAppResourceGroupName = functionAppResourceIdParts[4]
var functionAppName = last(functionAppResourceIdParts)
var validatedScheduledDateTimeUtc = dateTimeToEpoch(scheduledDateTimeUtc) > dateTimeToEpoch(deploymentTimeUtc)
  ? scheduledDateTimeUtc
  : fail('scheduledDateTimeUtc must be later than the deployment time.')

module updateMaintenanceRequest 'modules/updateMaintenanceRequest.bicep' = {
  name: 'schedule-${take(uniqueString(requestId), 8)}'
  scope: resourceGroup(functionAppSubscriptionId, functionAppResourceGroupName)
  params: {
    functionAppName: functionAppName
    requestId: requestId
    approvedImageDefinitionResourceId: approvedImageDefinitionResourceId
    approvedImageVersion: approvedImageVersion
    scheduledDateTimeUtc: validatedScheduledDateTimeUtc
    windowDurationMinutes: windowDurationMinutes
    maxVmsRemoved: maxVmsRemoved
    logOffDelayMinutes: logOffDelayMinutes
    logOffMessage: logOffMessage
    forceSignOut: forceSignOut
    allowFullPoolOutage: allowFullPoolOutage
    confirmNoShutdownRetention: confirmNoShutdownRetention
    replaceExistingRequest: replaceExistingRequest
  }
}

output requestId string = requestId
output functionAppResourceId string = functionAppResourceId
output scheduledDateTimeUtc string = scheduledDateTimeUtc
output requestStatus string = updateMaintenanceRequest.outputs.requestStatus

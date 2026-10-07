targetScope = 'resourceGroup'

param functionAppName string
param requestId string
param approvedImageDefinitionResourceId string
param approvedImageVersion string
param scheduledDateTimeUtc string
param windowDurationMinutes int
param maxVmsRemoved int
param logOffDelayMinutes int
param logOffMessage string
param forceSignOut bool
param allowFullPoolOutage bool
param confirmNoShutdownRetention bool
param replaceExistingRequest bool

resource functionApp 'Microsoft.Web/sites@2024-04-01' existing = {
  name: functionAppName
}

var existingAppSettings = list('${functionApp.id}/config/appsettings', '2024-04-01').properties
var replacementMode = contains(existingAppSettings, 'ReplacementMode') ? string(existingAppSettings.ReplacementMode) : ''
var existingMaintenanceRequest = contains(existingAppSettings, 'MaintenanceRequest') ? string(existingAppSettings.MaintenanceRequest) : ''
var hostPoolName = contains(existingAppSettings, 'HostPoolName') ? string(existingAppSettings.HostPoolName) : ''
var removeEntraDevice = contains(existingAppSettings, 'RemoveEntraDevice') ? toLower(string(existingAppSettings.RemoveEntraDevice)) == 'true' : false
var sessionHostParameters = contains(existingAppSettings, 'SessionHostParameters') && !empty(string(existingAppSettings.SessionHostParameters)) ? json(string(existingAppSettings.SessionHostParameters)) : {}
var identitySolution = contains(sessionHostParameters, 'identitySolution') ? string(sessionHostParameters.identitySolution) : ''
var imageReference = sessionHostParameters.?imageReference ?? {}
var configuredImageResourceId = contains(imageReference, 'id') ? string(imageReference.id) : ''
var configuredImageDefinitionResourceId = contains(toLower(configuredImageResourceId), '/versions/')
  ? join(take(split(configuredImageResourceId, '/'), 11), '/')
  : configuredImageResourceId
var isEntraJoined = contains([
  'EntraId'
  'EntraKerberos-Hybrid'
  'EntraKerberos-CloudOnly'
], identitySolution)

var maintenanceRequest = {
  requestId: requestId
  approvedImageVersion: approvedImageVersion
  scheduledDateTimeUtc: scheduledDateTimeUtc
  windowDurationMinutes: windowDurationMinutes
  maxVmsRemoved: maxVmsRemoved
  logOffDelayMinutes: logOffDelayMinutes
  logOffMessage: logOffMessage
  forceSignOut: forceSignOut
  allowFullPoolOutage: allowFullPoolOutage
}

var validationPassed = empty(hostPoolName) || !contains(existingAppSettings, 'SessionHostParameters')
  ? fail('The selected Function App is not a recognized Session Host Replacer.')
  : replacementMode != 'DeleteFirst'
    ? fail('Maintenance replacement can be scheduled only for a replacer configured in DeleteFirst mode.')
    : !empty(existingMaintenanceRequest) && !replaceExistingRequest
      ? fail('A maintenance request is already populated. Review it before authorizing replacement.')
      : !forceSignOut
        ? fail('forceSignOut must be authorized for maintenance replacement.')
        : !allowFullPoolOutage
          ? fail('allowFullPoolOutage must be authorized for maintenance replacement.')
          : !confirmNoShutdownRetention
            ? fail('Confirm that no shutdown-retained rollback VMs exist before scheduling maintenance.')
            : isEntraJoined && !removeEntraDevice
              ? fail('Entra device cleanup must be enabled before scheduling maintenance for Entra-joined session hosts.')
              : !empty(configuredImageDefinitionResourceId) && toLower(configuredImageDefinitionResourceId) != toLower(approvedImageDefinitionResourceId)
                ? fail('The approved Compute Gallery image definition does not match the replacer configuration.')
                : empty(configuredImageDefinitionResourceId) && !empty(approvedImageDefinitionResourceId)
                  ? fail('The replacer uses a Marketplace image, but a Compute Gallery image definition was supplied.')
                  : true

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union(existingAppSettings, {
    MaintenanceRequest: validationPassed ? string(maintenanceRequest) : ''
  })
}

output requestStatus string = 'Scheduled'

metadata name = 'AVD host pool'
metadata description = 'Deploys a host pool and updates its registration-token expiration, with optional diagnostics. Session hosts, application groups and workspace links are managed separately.'

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@description('Required. Name of the AVD host pool to deploy.')
param name string
@description('Optional. Azure region for the AVD host pool; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the AVD host pool.')
param tags object = {}

@description('Optional. Host pool desktop allocation model, such as Pooled or Personal.')
param hostPoolType string = 'Pooled'

@description('Optional. Session distribution algorithm for the host pool.')
param loadBalancerType string = 'BreadthFirst'

@description('Optional. Maximum concurrent sessions permitted per session host.')
param maxSessionLimit int = 10

@description('Optional. Enables a validation host pool.')
param validationEnvironment bool = false

@description('Optional. Custom RDP properties string.')
param customRdpProperty string = ''

@description('Optional. Public network access mode for this resource; private endpoints are configured separately.')
param publicNetworkAccess string = 'Enabled'

@description('Allow session hosts to be started when a user connects.')
param startVMOnConnect bool = false

@description('Optional. VM template JSON string for host pool.')
param vmTemplate string = ''

@description('Optional. Personal desktop assignment type.')
param personalDesktopAssignmentType string = ''

@description('Optional. Hours until registration token expires.')
param registrationTokenExpirationHours int = 24

@description('Optional. UTC reference timestamp used to calculate the host pool registration-token expiration.')
param utcValue string = utcNow('u')

// Referenced diagnostic destination resources must already exist.
@description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
param diagnosticSettings diagnosticSettingsType?

@description('Optional. Preferred application group type; defaults to Desktop.')
@allowed(['Desktop', 'RemoteApp'])
param preferredAppGroupType string = 'Desktop'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: name
  location: location
  tags: tags
  properties: {
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    validationEnvironment: validationEnvironment
    customRdpProperty: !empty(customRdpProperty) ? customRdpProperty : null
    publicNetworkAccess: publicNetworkAccess
    startVMOnConnect: startVMOnConnect
    vmTemplate: !empty(vmTemplate) ? vmTemplate : null
    personalDesktopAssignmentType: !empty(personalDesktopAssignmentType) ? personalDesktopAssignmentType : null
    registrationInfo: {
      expirationTime: dateTimeAdd(utcValue, 'PT${registrationTokenExpirationHours}H')
      registrationTokenOperation: 'Update'
    }
    preferredAppGroupType: preferredAppGroupType
  }
}

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
  scope: hostPool
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

@description('Resource ID of the AVD host pool.')
output resourceId string = hostPool.id
@description('Azure resource name of the AVD host pool.')
output name string = hostPool.name

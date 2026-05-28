import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

param hostPoolType string = 'Pooled'

param loadBalancerType string = 'BreadthFirst'

param maxSessionLimit int = 10

@description('Optional. Enables a validation host pool.')
param validationEnvironment bool = false

@description('Optional. Custom RDP properties string.')
param customRdpProperty string = ''

param publicNetworkAccess string = 'Enabled'

@description('Allow session hosts to be started when a user connects.')
param startVMOnConnect bool = false

@description('Optional. VM template JSON string for host pool.')
param vmTemplate string = ''

@description('Optional. Personal desktop assignment type.')
param personalDesktopAssignmentType string = ''

@description('Optional. Hours until registration token expires.')
param registrationTokenExpirationHours int = 24

param utcValue string = utcNow('u')

param diagnosticSettings diagnosticSettingsType?

@description('Preferred application group type to link to this host pool. If not specified, the system will determine the app group type based on host pool type and other factors.')
@allowed(['Desktop', 'RemoteApp'])
param preferredAppGroupType string = 'Desktop'

@description('Optional. Host pool management mode. Use Automated when deploying session host configuration/management resources.')
@allowed(['Manual', 'Automated'])
param managementMode string = 'Manual'

@description('Optional. Managed identity type for the host pool.')
@allowed(['None', 'SystemAssigned', 'UserAssigned'])
param identityType string = 'None'

@description('Conditional. Resource ID of a user-assigned managed identity for the host pool when identityType is UserAssigned.')
param userAssignedIdentityResourceId string = ''

var usePooledAutomatedApi = hostPoolType == 'Pooled' && managementMode == 'Automated'

var hostPoolProperties = union({
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
}, usePooledAutomatedApi ? {
  managementType: 'Automated'
} : {})

resource hostPool_manual 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = if (!usePooledAutomatedApi) {
  name: name
  location: location
  tags: tags
  identity: identityType == 'None'
    ? null
    : any({
        type: identityType
        userAssignedIdentities: identityType == 'UserAssigned'
          ? {
              '${userAssignedIdentityResourceId}': {}
            }
          : null
      })
  properties: hostPoolProperties
}

resource hostPool_automated 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' = if (usePooledAutomatedApi) {
  name: name
  location: location
  tags: tags
  identity: identityType == 'None'
    ? null
    : any({
        type: identityType
        userAssignedIdentities: identityType == 'UserAssigned'
          ? {
              '${userAssignedIdentityResourceId}': {}
            }
          : null
      })
  properties: hostPoolProperties
}

var deployDiagnosticSettings = diagnosticSettings != null && (!empty(diagnosticSettings.?workspaceId ?? '') || !empty(diagnosticSettings.?storageAccountId ?? '') || !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? ''))

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

resource diagnosticSetting_2023_09_05 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnosticSettings && !usePooledAutomatedApi) {
  scope: hostPool_manual
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

resource diagnosticSetting_2025_11_01_preview 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnosticSettings && usePooledAutomatedApi) {
  scope: hostPool_automated
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

output resourceId string = resourceId('Microsoft.DesktopVirtualization/hostPools', name)
output name string = name
output principalId string = identityType == 'None'
  ? ''
  : string(reference(resourceId('Microsoft.DesktopVirtualization/hostPools', name), usePooledAutomatedApi ? '2025-11-01-preview' : '2023-09-05', 'Full').identity.principalId)

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

@sys.description('Resource ID of the host pool this application group belongs to.')
param hostPoolResourceId string

@allowed(['Desktop', 'RemoteApp'])
param applicationGroupType string = 'Desktop'

@sys.description('Optional. Friendly name shown in the client.')
param friendlyName string = ''

@sys.description('Optional. Description of the application group.')
param description string = ''

param diagnosticSettings diagnosticSettingsType?

resource applicationGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: name
  location: location
  tags: tags
  properties: {
    applicationGroupType: applicationGroupType
    hostPoolArmPath: hostPoolResourceId
    friendlyName: !empty(friendlyName) ? friendlyName : null
    description: !empty(description) ? description : null
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
  scope: applicationGroup
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

output resourceId string = applicationGroup.id
output name string = applicationGroup.name

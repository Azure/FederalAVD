import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

@sys.description('Optional. Friendly name shown in the client.')
param friendlyName string = ''

@sys.description('Optional. Description of the workspace.')
param description string = ''

@allowed(['Enabled', 'Disabled', 'EnabledForClientsOnly'])
param publicNetworkAccess string = 'Enabled'

@sys.description('Application group resource IDs to link to this workspace.')
param applicationGroupResourceIds array = []

param diagnosticSettings diagnosticSettingsType?

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: name
  location: location
  tags: tags
  properties: {
    friendlyName: !empty(friendlyName) ? friendlyName : null
    description: !empty(description) ? description : null
    publicNetworkAccess: publicNetworkAccess
    applicationGroupReferences: applicationGroupResourceIds
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
  scope: workspace
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

output resourceId string = workspace.id
output name string = workspace.name

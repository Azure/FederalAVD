metadata name = 'AVD workspace'
metadata description = 'Deploys an AVD workspace with caller-supplied application group links and optional diagnostics. Application groups and user access are managed separately.'

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@sys.description('Required. Name of the AVD workspace to deploy.')
param name string
@sys.description('Optional. Azure region for the AVD workspace; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@sys.description('Optional. Tags applied to the AVD workspace.')
param tags object = {}

@sys.description('Optional. Friendly name shown in the client.')
param friendlyName string = ''

@sys.description('Optional. Description of the workspace.')
param description string = ''

@sys.description('Optional. Public network access mode for this resource; private endpoints are configured separately.')
param publicNetworkAccess 'Disabled' | 'Enabled' = 'Enabled'

@sys.description('Application group resource IDs to link to this workspace.')
param applicationGroupResourceIds array = []

// Referenced diagnostic destination resources must already exist.
@sys.description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
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

@sys.description('Resource ID of the AVD workspace.')
output resourceId string = workspace.id
@sys.description('Azure resource name of the AVD workspace.')
output name string = workspace.name

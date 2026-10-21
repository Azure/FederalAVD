metadata name = 'AVD application group'
metadata description = 'Deploys a Desktop or RemoteApp application group referencing an existing host pool, with optional diagnostics. Workspace links and user assignments are managed separately.'

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@sys.description('Required. Name of the AVD application group to deploy.')
param name string
@sys.description('Optional. Azure region for the AVD application group; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@sys.description('Optional. Tags applied to the AVD application group.')
param tags object = {}

@sys.description('Resource ID of the host pool this application group belongs to.')
param hostPoolResourceId string

@allowed(['Desktop', 'RemoteApp'])
@sys.description('Optional. Publish a full desktop or RemoteApp applications from the referenced host pool.')
param applicationGroupType string = 'Desktop'

@sys.description('Optional. Friendly name shown in the client.')
param friendlyName string = ''

@sys.description('Optional. Description of the application group.')
param description string = ''

// Referenced diagnostic destination resources must already exist.
@sys.description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
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

@sys.description('Resource ID of the AVD application group.')
output resourceId string = applicationGroup.id
@sys.description('Azure resource name of the AVD application group.')
output name string = applicationGroup.name

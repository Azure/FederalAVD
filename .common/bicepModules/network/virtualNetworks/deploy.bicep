import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

@description('Address space prefixes for the virtual network.')
param addressPrefixes array

@description('Optional. Array of subnet configuration objects.')
param subnets array = []

@description('Optional. Custom DNS server IP addresses.')
param dnsServers array = []

param diagnosticSettings diagnosticSettingsType?

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
    dhcpOptions: !empty(dnsServers) ? { dnsServers: dnsServers } : null
    subnets: subnets
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
  scope: virtualNetwork
  name: diagnosticSettingName
  properties: {
    workspaceId: diagnosticSettings.?workspaceId
    storageAccountId: diagnosticSettings.?storageAccountId
    eventHubAuthorizationRuleId: diagnosticSettings.?eventHubAuthorizationRuleId
    eventHubName: diagnosticSettings.?eventHubName
    logs: diagnosticSettings.?logCategories ?? [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output resourceId string = virtualNetwork.id
output name string = virtualNetwork.name

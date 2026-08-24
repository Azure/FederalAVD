import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@description('Required. Name of the automated pooled host pool.')
param name string

@description('Optional. Azure region for the host pool.')
param location string = resourceGroup().location

@description('Optional. Tags applied to the host pool.')
param tags object = {}

@description('Optional. Load-balancing algorithm for the pooled host pool.')
@allowed([
  'BreadthFirst'
  'DepthFirst'
])
param loadBalancerType string = 'DepthFirst'

@description('Optional. Maximum concurrent sessions per session host.')
@minValue(1)
param maxSessionLimit int = 10

@description('Optional. Deploy the host pool in the validation environment.')
param validationEnvironment bool = false

@description('Optional. Custom RDP properties applied to the host pool.')
param customRdpProperty string = ''

@description('Optional. Public network access mode for the host pool.')
@allowed([
  'Enabled'
  'Disabled'
  'EnabledForSessionHostsOnly'
  'EnabledForClientsOnly'
])
param publicNetworkAccess string = 'Enabled'

@description('Optional. Allow session hosts to start when a user connects.')
param startVMOnConnect bool = true

@description('Optional. VM template JSON string displayed by Azure Virtual Desktop.')
param vmTemplate string = ''

@description('Optional. Diagnostic settings for the host pool.')
param diagnosticSettings diagnosticSettingsType?

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: loadBalancerType
    managementType: 'Automated'
    maxSessionLimit: maxSessionLimit
    validationEnvironment: validationEnvironment
    customRdpProperty: !empty(customRdpProperty) ? customRdpProperty : null
    publicNetworkAccess: publicNetworkAccess
    startVMOnConnect: startVMOnConnect
    vmTemplate: !empty(vmTemplate) ? vmTemplate : null
    preferredAppGroupType: 'Desktop'
  }
}

var diagnosticSettingName = !empty(diagnosticSettings.?name ?? '') ? diagnosticSettings!.name! : 'WVDInsights'

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

output resourceId string = hostPool.id
output name string = hostPool.name
output principalId string = hostPool.identity.principalId

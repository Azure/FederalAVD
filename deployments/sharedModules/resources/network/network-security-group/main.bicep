metadata name = 'Network Security Groups'
metadata description = 'This module deploys a Network security Group (NSG).'
metadata owner = 'Azure/module-maintainers'

@description('Required. Name of the Network Security Group.')
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. Array of Security Rules to deploy to the Network Security Group. When not provided, an NSG including only the built-in roles will be deployed.')
param securityRules array = []

@description('Optional. When enabled, flows created from Network Security Group connections will be re-evaluated when rules are updates. Initial enablement will trigger re-evaluation. Network Security Group connection flushing is not available in all regions.')
param flushConnection bool = false

@description('Optional. Resource ID of the diagnostic storage account.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource ID of the diagnostic log analytics workspace.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category.')
param diagnosticEventHubName string = ''

@description('Optional. Tags of the NSG resource.')
param tags object = {}

@description('Optional. The name of logs that will be streamed. "allLogs" includes all possible logs for the resource. Set to \'\' to disable log collection.')
@allowed([
  ''
  'allLogs'
  'NetworkSecurityGroupEvent'
  'NetworkSecurityGroupRuleCounter'
])
param diagnosticLogCategoriesToEnable array = [
  'allLogs'
]

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

var diagnosticsLogsSpecified = [for category in filter(diagnosticLogCategoriesToEnable, item => item != 'allLogs' && item != ''): {
  category: category
  enabled: true
}]

var diagnosticsLogs = contains(diagnosticLogCategoriesToEnable, 'allLogs') ? [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
] : contains(diagnosticLogCategoriesToEnable, '') ? [] : diagnosticsLogsSpecified

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    flushConnection: flushConnection
    securityRules: [for securityRule in securityRules: {
      name: securityRule.name
      properties: {
        protocol: securityRule.properties.protocol
        access: securityRule.properties.access
        priority: securityRule.properties.priority
        direction: securityRule.properties.direction
        description: securityRule.properties.?description ?? ''
        sourcePortRange: securityRule.properties.?sourcePortRange ?? ''
        sourcePortRanges: securityRule.properties.?sourcePortRanges ?? []
        destinationPortRange: securityRule.properties.?destinationPortRange ?? ''
        destinationPortRanges: securityRule.properties.?destinationPortRanges ?? []
        sourceAddressPrefix: securityRule.properties.?sourceAddressPrefix ?? ''
        destinationAddressPrefix: securityRule.properties.?destinationAddressPrefix ?? ''
        sourceAddressPrefixes: securityRule.properties.?sourceAddressPrefixes ?? []
        destinationAddressPrefixes: securityRule.properties.?destinationAddressPrefixes ?? []
        sourceApplicationSecurityGroups: securityRule.properties.?sourceApplicationSecurityGroups ?? []
        destinationApplicationSecurityGroups: securityRule.properties.?destinationApplicationSecurityGroups ?? []
      }
    }]
  }
}

module networkSecurityGroup_securityRules 'security-rule/main.bicep' = [for (securityRule, index) in securityRules: {
  name: '${uniqueString(deployment().name, location)}-securityRule-${index}'
  params: {
    name: securityRule.name
    networkSecurityGroupName: networkSecurityGroup.name
    protocol: securityRule.properties.protocol
    access: securityRule.properties.access
    priority: securityRule.properties.priority
    direction: securityRule.properties.direction
    description: securityRule.properties.?description ?? ''
    sourcePortRange: securityRule.properties.?sourcePortRange ?? ''
    sourcePortRanges: securityRule.properties.?sourcePortRanges ?? []
    destinationPortRange: securityRule.properties.?destinationPortRange ?? ''
    destinationPortRanges: securityRule.properties.?destinationPortRanges ?? []
    sourceAddressPrefix: securityRule.properties.?sourceAddressPrefix ?? ''
    destinationAddressPrefix: securityRule.properties.?destinationAddressPrefix ?? ''
    sourceAddressPrefixes: securityRule.properties.?sourceAddressPrefixes ?? []
    destinationAddressPrefixes: securityRule.properties.?destinationAddressPrefixes ?? []
    sourceApplicationSecurityGroups: securityRule.properties.?sourceApplicationSecurityGroups ?? []
    destinationApplicationSecurityGroups: securityRule.properties.?destinationApplicationSecurityGroups ?? []
  }
}]

resource networkSecurityGroup_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(diagnosticStorageAccountId) || !empty(diagnosticWorkspaceId) || !empty(diagnosticEventHubAuthorizationRuleId) || !empty(diagnosticEventHubName)) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {
    storageAccountId: !empty(diagnosticStorageAccountId) ? diagnosticStorageAccountId : null
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    eventHubAuthorizationRuleId: !empty(diagnosticEventHubAuthorizationRuleId) ? diagnosticEventHubAuthorizationRuleId : null
    eventHubName: !empty(diagnosticEventHubName) ? diagnosticEventHubName : null
    logs: diagnosticsLogs
  }
  scope: networkSecurityGroup
}

@description('The resource group the network security group was deployed into.')
output resourceGroupName string = resourceGroup().name

@description('The resource ID of the network security group.')
output resourceId string = networkSecurityGroup.id

@description('The name of the network security group.')
output name string = networkSecurityGroup.name

@description('The location the resource was deployed into.')
output location string = networkSecurityGroup.location

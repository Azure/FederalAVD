@description('Required. The name of the network interface.')
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. Tags of the resource.')
param tags object = {}

@description('Optional. Indicates whether IP forwarding is enabled on this network interface.')
param enableIPForwarding bool = false

@description('Optional. If the network interface is accelerated networking enabled.')
param enableAcceleratedNetworking bool = false

@description('Optional. List of DNS servers IP addresses. Use \'AzureProvidedDNS\' to switch to azure provided DNS resolution. \'AzureProvidedDNS\' value cannot be combined with other IPs, it must be the only value in dnsServers collection.')
param dnsServers array = []

@description('Optional. The network security group (NSG) to attach to the network interface.')
param networkSecurityGroupResourceId string = ''

@allowed([
  'Floating'
  'MaxConnections'
  'None'
])
@description('Optional. Auxiliary mode of Network Interface resource. Not all regions are enabled for Auxiliary Mode Nic.')
param auxiliaryMode string = 'None'

@allowed([
  'A1'
  'A2'
  'A4'
  'A8'
  'None'
])
@description('Optional. Auxiliary sku of Network Interface resource. Not all regions are enabled for Auxiliary Mode Nic.')
param auxiliarySku string = 'None'

@description('Optional. Indicates whether to disable tcp state tracking. Subscription must be registered for the Microsoft.Network/AllowDisableTcpStateTracking feature before this property can be set to true.')
param disableTcpStateTracking bool = false

@description('Required. A list of IPConfigurations of the network interface.')
param ipConfigurations array

@description('Optional. Resource ID of the diagnostic storage account.')
param diagnosticStorageAccountId string = ''

@description('Optional. Resource identifier of log analytics.')
param diagnosticWorkspaceId string = ''

@description('Optional. Resource ID of the diagnostic event hub authorization rule for the Event Hubs namespace in which the event hub should be created or streamed to.')
param diagnosticEventHubAuthorizationRuleId string = ''

@description('Optional. Name of the diagnostic event hub within the namespace to which logs are streamed. Without this, an event hub is created for each log category.')
param diagnosticEventHubName string = ''

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'AllMetrics'
])
param diagnosticMetricsToEnable array = [
  'AllMetrics'
]

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

var diagnosticsMetrics = [for metric in diagnosticMetricsToEnable: {
  category: metric
  timeGrain: null
  enabled: true
}]

resource networkInterface 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    auxiliaryMode: auxiliaryMode
    auxiliarySku: auxiliarySku
    disableTcpStateTracking: disableTcpStateTracking
    dnsSettings: !empty(dnsServers) ? {
      dnsServers: dnsServers
    } : null
    enableAcceleratedNetworking: enableAcceleratedNetworking
    enableIPForwarding: enableIPForwarding
    networkSecurityGroup: !empty(networkSecurityGroupResourceId) ? {
      id: networkSecurityGroupResourceId
    } : null
    ipConfigurations: [for (ipConfiguration, index) in ipConfigurations: {
      name: ipConfiguration.?name ?? 'ipconfig0${index + 1}'
      properties: {
        primary: index == 0 ? true : false
        privateIPAllocationMethod: contains(ipConfiguration, 'privateIPAllocationMethod') ? (!empty(ipConfiguration.privateIPAllocationMethod) ? ipConfiguration.privateIPAllocationMethod : null) : null
        privateIPAddress: contains(ipConfiguration, 'privateIPAddress') ? (!empty(ipConfiguration.privateIPAddress) ? ipConfiguration.privateIPAddress : null) : null
        publicIPAddress: contains(ipConfiguration, 'publicIPAddressResourceId') ? (ipConfiguration.publicIPAddressResourceId != null ? {
          id: ipConfiguration.publicIPAddressResourceId
        } : null) : null
        subnet: {
          id: ipConfiguration.subnetResourceId
        }
        loadBalancerBackendAddressPools: ipConfiguration.?loadBalancerBackendAddressPools ?? null
        applicationSecurityGroups: ipConfiguration.?applicationSecurityGroups ?? null
        applicationGatewayBackendAddressPools: ipConfiguration.?applicationGatewayBackendAddressPools ?? null
        gatewayLoadBalancer: ipConfiguration.?gatewayLoadBalancer ?? null
        loadBalancerInboundNatRules: ipConfiguration.?loadBalancerInboundNatRules ?? null
        privateIPAddressVersion: ipConfiguration.?privateIPAddressVersion ?? null
        virtualNetworkTaps: ipConfiguration.?virtualNetworkTaps ?? null
      }
    }]
  }
}

resource networkInterface_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(diagnosticStorageAccountId) || !empty(diagnosticWorkspaceId) || !empty(diagnosticEventHubAuthorizationRuleId) || !empty(diagnosticEventHubName)) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {
    storageAccountId: !empty(diagnosticStorageAccountId) ? diagnosticStorageAccountId : null
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    eventHubAuthorizationRuleId: !empty(diagnosticEventHubAuthorizationRuleId) ? diagnosticEventHubAuthorizationRuleId : null
    eventHubName: !empty(diagnosticEventHubName) ? diagnosticEventHubName : null
    metrics: diagnosticsMetrics
  }
  scope: networkInterface
}

@description('The name of the deployed resource.')
output name string = networkInterface.name

@description('The resource ID of the deployed resource.')
output resourceId string = networkInterface.id

@description('The resource group of the deployed resource.')
output resourceGroupName string = resourceGroup().name

@description('The location the resource was deployed into.')
output location string = networkInterface.location

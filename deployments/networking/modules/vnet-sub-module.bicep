targetScope = 'subscription'

param deployVnetResourceGroup bool
param vnetName string
param vnetAddressPrefixes array
param hostsSubnet object
param privateEndpointsSubnet object
param functionAppSubnet object
param defaultRouting string
param natGatewayName string
param publicIPName string
param routeTableName string
param nsgName string
param logAnalyticsWorkspaceResourceId string
param nvaIPAddress string
param customDNSServers array
param deployDDoSNetworkProtection bool
param hubVnetName string
param hubVnetResourceGroup string
param hubVnetSubscriptionId string
param virtualNetworkGatewayOnHub bool
param vnetResourceGroupName string
param location string
param tags object
param timeStamp string

resource vNetResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = if (deployVnetResourceGroup) {
  name: vnetResourceGroupName
  location: location
  tags: tags[?'Microsoft.Resources/resourceGroups'] ?? {} 
}

module vnetResources 'vnetResources.bicep' = {
  scope: resourceGroup(vnetResourceGroupName)
  name: 'VNet-Resources-${timeStamp}'
  params: {
    vnetName: vnetName
    vnetAddressPrefixes: vnetAddressPrefixes
    hostsSubnet: hostsSubnet
    privateEndpointsSubnet: privateEndpointsSubnet
    functionAppSubnet: functionAppSubnet
    defaultRouting: defaultRouting
    natGatewayName: natGatewayName
    publicIPName: publicIPName
    routeTableName: routeTableName
    nsgName: nsgName
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    nvaIPAddress: nvaIPAddress
    customDNSServers: customDNSServers
    deployDDoSNetworkProtection: deployDDoSNetworkProtection
    hubVnetName: hubVnetName
    hubVnetResourceGroup: hubVnetResourceGroup
    hubVnetSubscriptionId: hubVnetSubscriptionId
    virtualNetworkGatewayOnHub: virtualNetworkGatewayOnHub
    location: location
    tags: tags
    timeStamp: timeStamp
  }
  dependsOn: [
    vNetResourceGroup
  ]
}

output vNetResourceId string = vnetResources.outputs.vnetResourceId

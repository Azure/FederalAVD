param vnetName string
param vnetAddressPrefixes array
param hostsSubnet object
param privateEndpointsSubnet object
param functionAppSubnet object
param defaultRouting string
param natGatewayName string
param publicIPName string
param routeTableName string
param nvaIPAddress string
param customDNSServers array
param deployDDoSNetworkProtection bool
param hubVnetName string
param hubVnetResourceGroup string
param hubVnetSubscriptionId string
param virtualNetworkGatewayOnHub bool
param location string
param tags object
param timeStamp string

var azureCloud = environment().name

var defaultUDRs = (azureCloud == 'AzureCloud')
  ? [
      {
        name: 'AVDServiceTraffic'
        properties: {
          addressPrefix: 'WindowsVirtualDesktop'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'AVDStunInfraTurnRelayTraffic'
        properties: {
          addressPrefix: '20.202.0.0/16'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'AVDTurnRelayTraffic'
        properties: {
          addressPrefix: '51.5.0.0/16'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'DirectRouteToKMS'
        properties: {
          addressPrefix: '20.118.99.224/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'DirectRouteToKMS01'
        properties: {
          addressPrefix: '40.83.235.53/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'DirectRouteToKMS02'
        properties: {
          addressPrefix: '23.102.135.246/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
    ]
  : (azureCloud == 'AzureUSGovernment')
      ? [
          {
            name: 'AVDServiceTraffic'
            properties: {
              addressPrefix: 'WindowsVirtualDesktop'
              hasBgpOverride: true
              nextHopType: 'Internet'
            }
          }
          {
            name: 'AVDStunTurnTraffic'
            properties: {
              addressPrefix: '20.202.0.0/16'
              hasBgpOverride: true
              nextHopType: 'Internet'
            }
          }
          {
            name: 'DirectRouteToKMS'
            properties: {
              addressPrefix: '23.97.0.13/32'
              hasBgpOverride: true
              nextHopType: 'Internet'
            }
          }
          {
            name: 'DirectRouteToKMS01'
            properties: {
              addressPrefix: '52.126.105.2/32'
              hasBgpOverride: true
              nextHopType: 'Internet'
            }
          }
        ]
      : []

var snetHosts = [
  {
    name: hostsSubnet.name
    properties: {
      addressPrefix: hostsSubnet.addressPrefix
      natGateway: defaultRouting == 'nat'
        ? {
            id: natGateway.id
          }
        : null
      routeTable: defaultRouting != 'nat'
        ? {
            id: routeTable.id
          }
        : null
    }
  }
]

var snetPrivateEndpoints = !empty(privateEndpointsSubnet)
  ? [
      {
        name: privateEndpointsSubnet.name
        properties: {
          addressPrefix: privateEndpointsSubnet.addressPrefix
        }
      }
    ]
  : []

var snetFunctionApp = !empty(functionAppSubnet)
  ? [
      {
        name: functionAppSubnet.name
        properties: {
          addressPrefix: functionAppSubnet.addressPrefix
          delegations: [
            {
              name: 'Microsoft.Web/serverFarms'
              properties: {
                ServiceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  : []

var subnets = union(snetHosts, snetPrivateEndpoints, snetFunctionApp)

resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2023-04-01' = if (deployDDoSNetworkProtection) {
  name: 'default'
  location: location
  tags: tags[?'Microsoft.Network/ddosProtectionPlans'] ?? {}
}

resource routeTable 'Microsoft.Network/routeTables@2023-04-01' = if (defaultRouting != 'nat') {
  name: routeTableName
  location: location
  properties: {
    routes: defaultRouting == 'default'
      ? defaultUDRs
      : defaultRouting == 'nva'
          ? [
              {
                name: 'DefaultRoute'
                properties: {
                  addressPrefix: '0.0.0.0/0'
                  nextHopType: 'VirtualAppliance'
                  nextHopIpAddress: nvaIPAddress
                }
              }
            ]
          : []
  }
  tags: tags[?'Microsoft.Network/routeTables'] ?? {}
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2021-05-01' = if (defaultRouting == 'nat') {
  name: publicIPName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
  tags: tags[?'Microsoft.Network/publicIPAddresses'] ?? {}
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = if (defaultRouting == 'nat') {
  name: natGatewayName
  location: location
  properties: {
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
    idleTimeoutInMinutes: 4    
  }
  sku: {
    name: 'Standard'
  }
  tags: tags[?'Microsoft.Network/natGateways'] ?? {}
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  location: location
  name: vnetName
  properties: {
    addressSpace: {
      addressPrefixes: vnetAddressPrefixes
    }
    ddosProtectionPlan: deployDDoSNetworkProtection
      ? {
          id: ddosProtectionPlan.id
        }
      : null
    dhcpOptions: !empty(customDNSServers)
      ? {
          dnsServers: customDNSServers
        }
      : null
    enableDdosProtection: deployDDoSNetworkProtection
  }
  tags: tags[?'Microsoft.Network/virtualNetworks'] ?? {}
}

@batchSize(1)
resource snets 'Microsoft.Network/virtualNetworks/subnets@2022-05-01' = [for subnet in subnets: {
  name: subnet.name
  parent: vnet
  properties: subnet.properties
}]

module localVnetPeering './virtual-network-peering.bicep' = if(!empty(hubVnetName)) {
  name: 'localVnetPeering-${timeStamp}'
  params: {
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    localVnetName: vnetName
    remoteVirtualNetworkId: '/subscriptions/${hubVnetSubscriptionId}/resourceGroups/${hubVnetResourceGroup}/providers/Microsoft.Network/virtualNetworks/${hubVnetName}'
    useRemoteGateways: virtualNetworkGatewayOnHub
  }
  dependsOn: [
    snets
  ]
}

module remoteVnetPeering './virtual-network-peering.bicep' = if(!empty(hubVnetName)) {
  name: 'remoteVnetPeering-${timeStamp}'
  scope: resourceGroup(hubVnetSubscriptionId, hubVnetResourceGroup)
  params: {
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    localVnetName: hubVnetName
    remoteVirtualNetworkId: vnet.id
    allowGatewayTransit: virtualNetworkGatewayOnHub
  }
  dependsOn: [
    snets
  ]
}

output vnetResourceId string = vnet.id

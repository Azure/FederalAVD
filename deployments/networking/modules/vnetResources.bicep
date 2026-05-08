param vnetName string
param vnetAddressPrefixes array
param subnets array
param defaultRouting string
param includeAvdBypassRoutes bool
param rdpShortpathManagedNetworks bool
param rdpShortpathPublicNetworks bool
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
param location string
param tags object
param timeStamp string

var azureCloud = environment().name

// NAT Gateway is needed for: NAT routing mode, AVD bypass routes (cone NAT ensures STUN works
// for service traffic), or RDP Shortpath on public networks (STUN requires cone-shaped NAT).
var deployNatGateway = defaultRouting == 'nat' || includeAvdBypassRoutes || rdpShortpathPublicNetworks

// AVD service tag bypass — covers broker, control plane, AND the 51.5.0.0/16 STUN/TURN relay
// range. Verified 2026-05-04: 51.5.0.0/16 is explicitly listed in the commercial
// WindowsVirtualDesktop service tag JSON (ServiceTags_Public_20260504.json).
// Used by both includeAvdBypassRoutes and rdpShortpathPublicNetworks.
//
// Azure US Government note:
// TURN relay is not available in Azure US Government (per Microsoft docs). The gov
// WindowsVirtualDesktop service tag (ServiceTags_AzureGovernment_20260504.json) contains
// only 20.140.236.0/22 and 20.159.80.0/24 (broker/reverse-connect) — no STUN-specific range.
// The previously referenced 20.202.0.0/16 range (old ACS TURN shared infra) is absent from
// the gov JSON entirely. Traffic to 20.202.0.0/16 observed from gov AVD sessions is likely
// client-side ICE/STUN probing (not session host egress) and is not subject to subnet UDRs.
// If a dedicated gov STUN range is published in the future, add it as a separate route here.
var wvdServiceRoute = [
  {
    name: 'AVDServiceTraffic'
    properties: {
      addressPrefix: 'WindowsVirtualDesktop'
      hasBgpOverride: true
      nextHopType: 'Internet'
    }
  }
]

// KMS routes — license activation bypass; included only with includeAvdBypassRoutes.
// KMS IPs are only known for AzureCloud and AzureUSGovernment. Air-gapped clouds
// (AzureChinaCloud, AzureGermanCloud, etc.) intentionally receive no KMS routes because
// the correct IPs for those clouds are unknown and adding commercial/gov IPs would be wrong.
// If KMS bypass is needed for an air-gapped cloud, add a new conditional var here with the
// verified IPs for that cloud.
// https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/windows/custom-routes-enable-kms-activation
var commercialKmsRoutes = (azureCloud == 'AzureCloud')
  ? [
      {
        name: 'DirectRouteToKMS01'
        properties: {
          addressPrefix: '20.118.99.224/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'DirectRouteToKMS02'
        properties: {
          addressPrefix: '40.83.235.53/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'DirectRouteToKMS03'
        properties: {
          addressPrefix: '23.102.135.246/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
    ]
  : []

var govKmsRoutes = (azureCloud == 'AzureUSGovernment')
  ? [
      {
        name: 'DirectRouteToKMS01'
        properties: {
          addressPrefix: '23.97.0.13/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
      {
        name: 'DirectRouteToKMS02'
        properties: {
          addressPrefix: '52.126.105.2/32'
          hasBgpOverride: true
          nextHopType: 'Internet'
        }
      }
    ]
  : []

// Routes added when includeAvdBypassRoutes = true: WVD service tag (covers STUN/TURN via 51.5.0.0/16) + KMS.
var avdBypassRoutes = union(wvdServiceRoute, commercialKmsRoutes, govKmsRoutes)

// Routes needed for RDP Shortpath public networks on an NVA deployment.
// The WindowsVirtualDesktop service tag includes 51.5.0.0/16 (STUN/TURN relay), so this
// single route ensures STUN/TURN traffic bypasses the NVA and egresses via the NAT Gateway
// for cone-shaped NAT. No separate IP range route required.
var shortpathBypassRoutes = wvdServiceRoute

// Effective bypass routes are the union of whichever feature sets are enabled.
// union() deduplicates identical route objects so there is no double-entry.
var effectiveBypassRoutes = union(
  includeAvdBypassRoutes ? avdBypassRoutes : [],
  (rdpShortpathPublicNetworks && defaultRouting == 'nva') ? shortpathBypassRoutes : []
)

// NSG rules — built conditionally based on RDP Shortpath feature selections.
//
// Managed networks: requires an inbound UDP 3390 rule. The session host runs a static
// RDP Shortpath listener on 3390; clients on the private network connect directly to it.
//
// Public networks (STUN/ICE): NO inbound NSG rule is needed. The session host opens
// outbound ephemeral UDP ports to probe the STUN server; the NAT Gateway's cone-shaped
// NAT mapping allows the client's simultaneous hole-punch traffic back in through the
// existing mapping. The client never initiates a new inbound connection on a predictable
// port — ICE handles NAT traversal entirely via the outbound-initiated cone NAT session.
var nsgRules_ManagedShortpath = rdpShortpathManagedNetworks
  ? [
      {
        name: 'RDPShortpathManagedNetworks'
        properties: {
          priority: 150
          access: 'Allow'
          description: 'Allow inbound UDP 3390 from VirtualNetwork for RDP Shortpath on managed networks (ExpressRoute/VPN).'
          destinationAddressPrefix: 'VirtualNetwork'
          direction: 'Inbound'
          sourcePortRange: '*'
          destinationPortRange: '3390'
          protocol: 'Udp'
          sourceAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  : []

var nsgSecurityRules = nsgRules_ManagedShortpath

var hostsSubnetsList = filter(subnets, s => s.purpose == 'hosts')
var peSubnetsList = filter(subnets, s => s.purpose == 'privateEndpoints')
var faSubnetsList = filter(subnets, s => s.purpose == 'functionApp')

var snetHosts = [for subnet in hostsSubnetsList: {
  name: subnet.name
  properties: {
    addressPrefix: subnet.addressPrefix
    natGateway: deployNatGateway
      ? {
          id: natGateway.id
        }
      : null
    routeTable: defaultRouting != 'nat'
      ? {
          id: routeTable.id
        }
      : null
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}]

var snetPrivateEndpoints = !empty(peSubnetsList)
  ? [
      {
        name: peSubnetsList[0].name
        properties: {
          addressPrefix: peSubnetsList[0].addressPrefix
        }
      }
    ]
  : []

var snetFunctionApp = !empty(faSubnetsList)
  ? [
      {
        name: faSubnetsList[0].name
        properties: {
          addressPrefix: faSubnetsList[0].addressPrefix
          natGateway: deployNatGateway
            ? {
                id: natGateway.id
              }
            : null
          routeTable: defaultRouting != 'nat'
            ? {
                id: routeTable.id
              }
            : null
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

var allSubnets = union(snetHosts, snetPrivateEndpoints, snetFunctionApp)

resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2023-04-01' = if (deployDDoSNetworkProtection) {
  name: 'default'
  location: location
  tags: tags[?'Microsoft.Network/ddosProtectionPlans'] ?? {}
}

resource routeTable 'Microsoft.Network/routeTables@2023-04-01' = if (defaultRouting == 'nva') {
  name: routeTableName
  location: location
  properties: {
    routes: !empty(effectiveBypassRoutes)
      ? concat(
          [
            {
              name: 'DefaultRoute'
              properties: {
                addressPrefix: '0.0.0.0/0'
                nextHopType: 'VirtualAppliance'
                nextHopIpAddress: nvaIPAddress
              }
            }
          ],
          effectiveBypassRoutes
        )
      : [
          {
            name: 'DefaultRoute'
            properties: {
              addressPrefix: '0.0.0.0/0'
              nextHopType: 'VirtualAppliance'
              nextHopIpAddress: nvaIPAddress
            }
          }
        ]
  }
  tags: tags[?'Microsoft.Network/routeTables'] ?? {}
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2021-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: nsgSecurityRules
  }
  tags: tags[?'Microsoft.Network/networkSecurityGroups'] ?? {}
}

resource nsgDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: '${nsgName}-diagnosticSettings'
  scope: nsg
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspaceResourceId
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2021-05-01' = if (deployNatGateway) {
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

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = if (deployNatGateway) {
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
resource snets 'Microsoft.Network/virtualNetworks/subnets@2022-05-01' = [
  for subnet in allSubnets: {
    name: subnet.name
    parent: vnet
    properties: subnet.properties
  }
]

module localVnetPeering './virtual-network-peering.bicep' = if (!empty(hubVnetName)) {
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

module remoteVnetPeering './virtual-network-peering.bicep' = if (!empty(hubVnetName)) {
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

metadata name = 'Virtual network peering'
metadata description = 'Deploys one directional peering from an existing local virtual network to an existing remote network. Reverse peering and gateway prerequisites are managed separately.'

@description('Required. Name of the virtual network peering to deploy.')
param name string
@description('Required. Name of the existing local virtual network in the deployment resource group.')
param vnetName string

@description('Resource ID of the remote virtual network.')
param remoteVnetId string

@description('Optional. Allow traffic between the local and remote virtual network address spaces.')
param allowVirtualNetworkAccess bool = true
@description('Optional. Allow traffic forwarded from the remote virtual network.')
param allowForwardedTraffic bool = false
@description('Optional. Allow the remote virtual network to use the local gateway through this peering.')
param allowGatewayTransit bool = false
@description('Optional. Use the remote virtual network gateway; requires gateway transit on the reverse peering.')
param useRemoteGateways bool = false

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: vnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: virtualNetwork
  name: name
  properties: {
    remoteVirtualNetwork: { id: remoteVnetId }
    allowVirtualNetworkAccess: allowVirtualNetworkAccess
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}

@description('Resource ID of the virtual network peering.')
output resourceId string = peering.id
@description('Azure resource name of the virtual network peering.')
output name string = peering.name

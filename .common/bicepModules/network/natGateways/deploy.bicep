param name string
param location string = resourceGroup().location
param tags object = {}

@description('Optional. Public IP address resource IDs to associate with this NAT gateway.')
param publicIPAddressIds array = []

@description('Idle timeout in minutes for TCP connections.')
param idleTimeoutInMinutes int = 4

resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: idleTimeoutInMinutes
    publicIpAddresses: [for id in publicIPAddressIds: { id: id }]
  }
}

output resourceId string = natGateway.id
output name string = natGateway.name

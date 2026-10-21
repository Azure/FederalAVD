metadata name = 'NAT gateway'
metadata description = 'Deploys a Standard NAT gateway with optional existing public IP addresses. Subnet associations are configured separately.'

@description('Required. Name of the nAT gateway to deploy.')
param name string
@description('Optional. Azure region for the nAT gateway; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the nAT gateway.')
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

@description('Resource ID of the nAT gateway.')
output resourceId string = natGateway.id
@description('Azure resource name of the nAT gateway.')
output name string = natGateway.name

metadata name = 'Network interface'
metadata description = 'Deploys a private NIC in an existing subnet with optional static addressing, accelerated networking and an existing network security group.'

@description('Required. Name of the network interface to deploy.')
param name string
@description('Optional. Azure region for the network interface; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the network interface.')
param tags object = {}

@description('Resource ID of the subnet to attach this NIC to.')
param subnetResourceId string

@allowed(['Dynamic', 'Static'])
@description('Optional. Private address allocation mode; Static requires privateIPAddress.')
param privateIPAllocationMethod string = 'Dynamic'

@description('Optional. Static private IP address. Required when privateIPAllocationMethod is Static.')
param privateIPAddress string = ''

@description('Optional. Resource ID of a Network Security Group to associate with this NIC.')
param nsgResourceId string = ''

@description('Optional. Enable accelerated networking on the NIC; the consuming VM size and OS must support it.')
param enableAcceleratedNetworking bool = false

resource networkInterface 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: enableAcceleratedNetworking
    networkSecurityGroup: !empty(nsgResourceId) ? { id: nsgResourceId } : null
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetResourceId }
          privateIPAllocationMethod: privateIPAllocationMethod
          privateIPAddress: privateIPAllocationMethod == 'Static' ? privateIPAddress : null
        }
      }
    ]
  }
}

@description('Resource ID of the network interface.')
output resourceId string = networkInterface.id
@description('Azure resource name of the network interface.')
output name string = networkInterface.name

param name string
param location string = resourceGroup().location
param tags object = {}

@description('Resource ID of the subnet to attach this NIC to.')
param subnetResourceId string

@allowed(['Dynamic', 'Static'])
param privateIPAllocationMethod string = 'Dynamic'

@description('Optional. Static private IP address. Required when privateIPAllocationMethod is Static.')
param privateIPAddress string = ''

@description('Optional. Resource ID of a Network Security Group to associate with this NIC.')
param nsgResourceId string = ''

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

output resourceId string = networkInterface.id
output name string = networkInterface.name

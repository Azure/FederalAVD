param netAppAccountName string
param name string
param location string = resourceGroup().location
param tags object = {}

@allowed(['Premium', 'Standard', 'Ultra'])
param serviceLevel string = 'Standard'

@description('Provisioned size of the pool in TiB. Minimum 4 TiB.')
param sizeTiB int = 4

resource netAppAccount 'Microsoft.NetApp/netAppAccounts@2023-07-01' existing = {
  name: netAppAccountName
}

resource capacityPool 'Microsoft.NetApp/netAppAccounts/capacityPools@2023-07-01' = {
  parent: netAppAccount
  name: name
  location: location
  tags: tags
  properties: {
    serviceLevel: serviceLevel
    size: sizeTiB * 1099511627776 // TiB to bytes
  }
}

output resourceId string = capacityPool.id
output name string = capacityPool.name

metadata name = 'NetApp capacity pool'
metadata description = 'Deploys a capacity pool under an existing NetApp account in the deployment resource group, converting the caller-supplied TiB capacity to bytes.'

@description('Required. Name of the existing parent NetApp account in the deployment resource group.')
param netAppAccountName string
@description('Required. Name of the netApp capacity pool within its parent resource.')
param name string
@description('Optional. Azure region for the netApp capacity pool; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the netApp capacity pool.')
param tags object = {}

@allowed(['Premium', 'Standard', 'Ultra'])
@description('Optional. NetApp service level; must be compatible with the selected account or capacity pool.')
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

@description('Resource ID of the netApp capacity pool.')
output resourceId string = capacityPool.id
@description('Azure resource name of the netApp capacity pool.')
output name string = capacityPool.name

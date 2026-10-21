metadata name = 'Route table'
metadata description = 'Deploys a route table with caller-supplied routes and BGP propagation settings; subnet associations are configured separately.'

@description('Required. Name of the route table to deploy.')
param name string
@description('Optional. Azure region for the route table; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the route table.')
param tags object = {}

@description('Optional. Array of route objects.')
param routes array = []

@description('Disable BGP route propagation on this route table.')
param disableBgpRoutePropagation bool = false

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: disableBgpRoutePropagation
    routes: routes
  }
}

@description('Resource ID of the route table.')
output resourceId string = routeTable.id
@description('Azure resource name of the route table.')
output name string = routeTable.name

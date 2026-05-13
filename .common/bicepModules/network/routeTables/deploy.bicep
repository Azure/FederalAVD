param name string
param location string = resourceGroup().location
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

output resourceId string = routeTable.id
output name string = routeTable.name

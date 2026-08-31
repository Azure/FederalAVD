@description('Required. Name of the parent automated host pool.')
param hostPoolName string

@description('Required. Session Host Configuration properties.')
param properties resourceInput<'Microsoft.DesktopVirtualization/hostPools/sessionHostConfigurations@2025-11-01-preview'>.properties

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' existing = {
  name: hostPoolName
}

resource sessionHostConfiguration 'Microsoft.DesktopVirtualization/hostPools/sessionHostConfigurations@2025-11-01-preview' = {
  parent: hostPool
  name: 'default'
  properties: properties
}

output resourceId string = sessionHostConfiguration.id
output name string = sessionHostConfiguration.name

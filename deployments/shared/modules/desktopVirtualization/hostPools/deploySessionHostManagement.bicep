@description('Required. Name of the parent automated host pool.')
param hostPoolName string

@description('Required. Session Host Management properties.')
param properties resourceInput<'Microsoft.DesktopVirtualization/hostPools/sessionHostManagements@2025-11-01-preview'>.properties

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-11-01-preview' existing = {
  name: hostPoolName
}

resource sessionHostManagement 'Microsoft.DesktopVirtualization/hostPools/sessionHostManagements@2025-11-01-preview' = {
  parent: hostPool
  name: 'default'
  properties: properties
}

output resourceId string = sessionHostManagement.id
output name string = sessionHostManagement.name

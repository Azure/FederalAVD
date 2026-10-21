metadata name = 'Automated session host configuration'
metadata description = 'Creates or updates the default session host configuration under an existing automated host pool in the deployment resource group using caller-supplied properties.'

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

@description('Resource ID of the automated session host configuration.')
output resourceId string = sessionHostConfiguration.id
@description('Azure resource name of the automated session host configuration.')
output name string = sessionHostConfiguration.name

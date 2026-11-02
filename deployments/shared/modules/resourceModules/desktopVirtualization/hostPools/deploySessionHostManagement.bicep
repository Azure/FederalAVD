metadata name = 'Automated session host management'
metadata description = 'Creates or updates the default session host management settings under an existing automated host pool in the deployment resource group using caller-supplied properties.'

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

@description('Resource ID of the automated session host management.')
output resourceId string = sessionHostManagement.id
@description('Azure resource name of the automated session host management.')
output name string = sessionHostManagement.name

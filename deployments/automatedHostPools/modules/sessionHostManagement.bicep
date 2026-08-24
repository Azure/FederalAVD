targetScope = 'subscription'

@description('Required. Resource group containing the automated host pool.')
param resourceGroupName string

@description('Required. Automated host-pool name.')
param hostPoolName string

@description('Required. Session Host Management properties.')
param properties resourceInput<'Microsoft.DesktopVirtualization/hostPools/sessionHostManagements@2025-11-01-preview'>.properties

module sessionHostManagement '../../shared/modules/desktopVirtualization/hostPools/deploySessionHostManagement.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    hostPoolName: hostPoolName
    properties: properties
  }
}

output resourceId string = sessionHostManagement.outputs.resourceId

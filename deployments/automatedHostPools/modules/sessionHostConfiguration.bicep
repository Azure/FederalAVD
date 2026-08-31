targetScope = 'subscription'

@description('Required. Resource group containing the automated host pool.')
param resourceGroupName string

@description('Required. Automated host-pool name.')
param hostPoolName string

@description('Required. Session Host Configuration properties.')
param properties resourceInput<'Microsoft.DesktopVirtualization/hostPools/sessionHostConfigurations@2025-11-01-preview'>.properties

module sessionHostConfiguration '../../shared/modules/resourceModules/desktopVirtualization/hostPools/deploySessionHostConfiguration.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    hostPoolName: hostPoolName
    properties: properties
  }
}

output resourceId string = sessionHostConfiguration.outputs.resourceId

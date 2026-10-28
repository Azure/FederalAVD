targetScope = 'subscription'

import { functionAppNames } from '../../deployments/shared/modules/orchestration/naming/functions.bicep'

param identifier string = 'inventory'
param location string = 'eastus'
param targetSubscriptionId string = subscription().subscriptionId
param targetResourceGroupName string = 'rg-addons'
param namingConvention object = {}
param functionAppNameOverride string = ''
param storageAccountNameOverride string = ''
param serverFarmId string
param hostPoolResourceId string

var names = functionAppNames(namingConvention, identifier, {
  subscriptionId: targetSubscriptionId
  resourceGroupName: targetResourceGroupName
  location: location
  cloud: environment().name
})

module app '../../deployments/shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  name: 'function-app'
  scope: resourceGroup(targetSubscriptionId, targetResourceGroupName)
  params: {
    functionAppName: !empty(functionAppNameOverride) ? functionAppNameOverride : names.functionAppName
    storageAccountName: !empty(storageAccountNameOverride) ? storageAccountNameOverride : names.storageAccountName
    applicationInsightsName: names.applicationInsightsName
    privateEndpointNameConv: names.privateEndpointNameConv
    privateEndpointNICNameConv: names.privateEndpointNICNameConv
    serverFarmId: serverFarmId
    hostPoolResourceId: hostPoolResourceId
    location: location
    azureBlobPrivateDnsZoneResourceId: ''
    azureFunctionAppPrivateDnsZoneResourceId: ''
    azureTablePrivateDnsZoneResourceId: ''
    encryptionKeyName: ''
    encryptionKeyVaultResourceId: ''
    functionAppDelegatedSubnetResourceId: ''
    functionAppAppSettings: []
    keyManagementStorageAccounts: 'PlatformManaged'
    privateEndpoint: false
    privateEndpointSubnetResourceId: ''
    tags: {
      functionApps: {}
      storageAccounts: {}
      applicationInsights: {}
      privateEndpoints: {}
      networkInterfaces: {}
    }
  }
}

output generatedNames object = names

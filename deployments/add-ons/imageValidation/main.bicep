targetScope = 'subscription'

param location string = deployment().location

param namingComponentOrder array = [
  
]

var names = {
  resourceGroup: replace(namingStandard, 'resourceType', 'rg')
  userAssignedIdentity: replace(namingStandard, 'resourceType', 'uami')
}

var namingStandard = ''

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: names.resourceGroup
  location: location
}

// Managed Identity with role assignments
module userAssignedIdentity '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: rg
  params: {
    location: location
    name: names.userAssignedIdentity
  }
}

module serverFarm '../../shared/modules/resourceModules/functionApp/functionAppHostingPlan.bicep' = {
  scope: rg
  params: {
    location: location
    functionAppKind: 
    hostingPlanType:
    name:
    planPricing:
    tags:
    zoneRedundant:
  }
}

module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  scope: rg
  params: {
    azureBlobPrivateDnsZoneResourceId:
    azureFunctionAppPrivateDnsZoneResourceId:
    encryptionKeyName:
    encryptionKeyVaultResourceId:
    functionAppAppSettings:
    functionAppDelegatedSubnetResourceId:
    functionAppName:
    hostPoolResourceId:
    keyManagementStorageAccounts:
    location: location
    privateEndpoint:
    privateEndpointNameConv:
    privateEndpointNICNameConv:
    privateEndpointSubnetResourceId:
    serverFarmId:
    storageAccountName:
    tags:
  }
}

module function '../../shared/modules/resourceModules/functionApp/function.bicep' = {
  scope: rg
  params: {
    location: location
    files:
    functionAppName:
    functionName:
    schedule:
  }
}

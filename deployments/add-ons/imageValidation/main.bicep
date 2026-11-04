targetScope = 'subscription'

metadata name = 'Image validation infrastructure'
metadata description = 'Deploys private Windows PowerShell timer Function infrastructure. Validation code and workload permissions are supplied by the operator.'

import { functionAppNames, resourceNameForType } from '../../shared/modules/orchestration/naming/naming.bicep'

@description('Optional. Complete name override for a new App Service plan. Ignored when using an existing plan ID.')
param appServicePlanNameOverride string = ''

@description('Required for private mode. Existing target-cloud blob private DNS zone ID, linked to the integration VNet.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Function App private DNS zone ID, linked to the integration VNet.')
param azureFunctionAppPrivateDnsZoneResourceId string = ''

@description('Optional. Existing same-region Windows Dedicated App Service plan ID. Empty creates a dedicated PremiumV3_P0v3 plan.')
param existingAppServicePlanResourceId string = ''

@description('Optional. Additional Function App settings. Do not include secrets; use managed identity or Key Vault references.')
param functionAppAppSettings {
  name: string
  value: string
}[] = []

@description('Required for private mode. Existing Microsoft.Web/serverFarms-delegated integration subnet in the app region, separate from the endpoint subnet.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Optional. Complete Function App name override.')
@maxLength(60)
param functionAppNameOverride string = ''

@description('Optional. Short add-on identifier used by the centralized naming policy. Use distinct identifiers for independent instances.')
@minLength(1)
param identifier string = 'iv'

@description('Required. Existing Azure Compute Gallery image definition resource ID.')
param imageDefinitionResourceId string

@description('Optional. Azure region for the resource group and Function infrastructure.')
param location string = deployment().location

@description('Optional. Existing workspace ID. Nonempty enables Application Insights and FunctionAppLogs diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Shared naming convention overrides. Empty uses the centralized FederalAVD defaults.')
param namingConvention object = {}

@description('Optional. Create private endpoints and disable public app/storage access. Requires existing subnets and private DNS zones.')
param privateEndpoint bool = true

@description('Required for private mode. Existing subnet for app and blob private endpoints.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Existing Azure Monitor Private Link Scope ID. Without it, enabled Insights uses public ingestion and query endpoints.')
param privateLinkScopeResourceId string = ''

@description('Optional. Complete resource group name override. The deployment manages this group.')
param resourceGroupNameOverride string = ''

@description('Required. Timer schedule in six-field Functions NCRONTAB format or a supported app-setting reference.')
@minLength(1)
param schedule string

@description('Optional. Complete runtime storage name override, also useful when generated storage names exceed 24 characters.')
@maxLength(24)
param storageAccountNameOverride string = ''

@description('Optional. Flat tags applied to all add-on resource types.')
param tags object = {}

@description('Optional. Complete name override for the Function App identity.')
param userAssignedIdentityNameOverride string = ''

var groupContext = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: ''
  location: location
  cloud: environment().name
}
var resourceGroupName = !empty(resourceGroupNameOverride)
  ? resourceGroupNameOverride
  : resourceNameForType(namingConvention, 'resourceGroups', identifier, groupContext)
var namingContext = union(groupContext, { resourceGroupName: resourceGroupName })
var names = union(functionAppNames(namingConvention, identifier, namingContext, {
  functionAppName: functionAppNameOverride
  storageAccountName: storageAccountNameOverride
}), {
  resourceGroup: resourceGroupName
  userAssignedIdentity: !empty(userAssignedIdentityNameOverride)
    ? userAssignedIdentityNameOverride
    : resourceNameForType(namingConvention, 'userAssignedIdentities', identifier, namingContext)
  appServicePlanName: !empty(existingAppServicePlanResourceId)
    ? last(split(existingAppServicePlanResourceId, '/'))
    : !empty(appServicePlanNameOverride)
      ? appServicePlanNameOverride
      : resourceNameForType(namingConvention, 'appServicePlans', identifier, namingContext)
})

var integrationSubnetId = privateEndpoint && empty(trim(functionAppDelegatedSubnetResourceId))
  ? fail('Private mode requires functionAppDelegatedSubnetResourceId.')
  : functionAppDelegatedSubnetResourceId
var endpointSubnetId = privateEndpoint && empty(trim(privateEndpointSubnetResourceId))
  ? fail('Private mode requires privateEndpointSubnetResourceId.')
  : privateEndpointSubnetResourceId
var blobDnsZoneId = privateEndpoint && empty(trim(azureBlobPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureBlobPrivateDnsZoneResourceId.')
  : azureBlobPrivateDnsZoneResourceId
var appDnsZoneId = privateEndpoint && empty(trim(azureFunctionAppPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureFunctionAppPrivateDnsZoneResourceId.')
  : azureFunctionAppPrivateDnsZoneResourceId
var resourceTags = {
  'Microsoft.Web/serverfarms': tags
  'Microsoft.Web/sites': tags
  'Microsoft.Storage/storageAccounts': tags
  'Microsoft.Insights/components': tags
  'Microsoft.Network/privateEndpoints': tags
  'Microsoft.Network/networkInterfaces': tags
}

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: names.resourceGroup
  location: location
  tags: tags
}

module userAssignedIdentity '../../shared/modules/resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: rg
  params: {
    location: location
    name: names.userAssignedIdentity
    tags: tags
  }
}

module templateSpec 'modules/templateSpec.bicep' = {
  scope: rg
  params: {
    imageDefinitionName: last(split(imageDefinitionResourceId, '/'))
    location: location
    templateSpecName: names.templateSpecName
  }
}

module serverFarm '../../shared/modules/resourceModules/functionApp/functionAppHostingPlan.bicep' = if (empty(existingAppServicePlanResourceId)) {
  scope: rg
  params: {
    functionAppKind: 'functionapp'
    hostingPlanType: 'Dedicated'
    location: location
    name: names.appServicePlanName
    planPricing: 'PremiumV3_P0v3'
    tags: resourceTags
    zoneRedundant: false
  }
}

module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  scope: rg
  params: {
    applicationInsightsName: names.applicationInsightsName
    azureBlobPrivateDnsZoneResourceId: blobDnsZoneId
    azureFunctionAppPrivateDnsZoneResourceId: appDnsZoneId
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    enableQueueStorage: false
    enableTableStorage: false
    encryptionKeyName: ''
    encryptionKeyVaultResourceId: ''
    functionAppAppSettings: functionAppAppSettings
    functionAppDelegatedSubnetResourceId: integrationSubnetId
    functionAppName: names.functionAppName
    functionAppUserAssignedIdentityResourceId: userAssignedIdentity.outputs.resourceId
    hostPoolResourceId: ''
    keyManagementStorageAccounts: 'PlatformManaged'
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    paasPublicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: names.privateEndpointNameConv
    privateEndpointNICNameConv: names.privateEndpointNICNameConv
    privateEndpointSubnetResourceId: endpointSubnetId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    serverFarmId: !empty(existingAppServicePlanResourceId) ? existingAppServicePlanResourceId : serverFarm!.outputs.hostingPlanId
    storageAccountName: names.storageAccountName
    tags: resourceTags
  }
}

module function '../../shared/modules/resourceModules/functionApp/function.bicep' = {
  scope: rg
  params: {
    files: {
      'requirements.psd1': loadTextContent('./scripts/requirements.psd1')
      'run.ps1': loadTextContent('./scripts/run.ps1')
      '../profile.ps1': loadTextContent('./scripts/profile.ps1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'ImageValidation'
    schedule: schedule
  }
}

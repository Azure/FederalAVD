metadata name = 'FSLogix Storage Quota Manager Add-On'
metadata description = 'Automated quota management for FSLogix Azure Files Premium file shares'
metadata owner = 'FederalAVD'

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Common Parameters
// These parameters apply to the overall deployment and are shared across multiple resources.
// ================================================================================================

@description('Optional. The location for all resources. Defaults to deployment location.')
param location string = resourceGroup().location

@description('Optional. Tags for all resources.')
param tags object = {}

// ================================================================================================
// Function App Infrastructure Parameters
// These parameters configure the Azure Function App infrastructure including networking, 
// security, encryption, and monitoring capabilities.
// ================================================================================================

@description('Optional. The resource ID of an existing App Service Plan for the function app. If not provided, a new plan will be deployed.')
param appServicePlanResourceId string = ''

@description('Optional. Whether to deploy the App Service Plan with zone redundancy. Only applies if appServicePlanResourceId is not provided. Default is false.')
param zoneRedundant bool = false

@description('Optional. Enable private endpoints for function app and storage. Default is false.')
param privateEndpoint bool = false

@description('Optional. The subnet resource ID for private endpoints. Required if privateEndpoint is true.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. The subnet resource ID for the function app VNet integration. Required if privateEndpoint is true.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Optional. Private DNS Zone resource IDs. Required if privateEndpoint is true.')
param azureBlobPrivateDnsZoneResourceId string = ''
param azureFilePrivateDnsZoneResourceId string = ''
param azureFunctionAppPrivateDnsZoneResourceId string = ''
param azureQueuePrivateDnsZoneResourceId string = ''
param azureTablePrivateDnsZoneResourceId string = ''

@description('Optional. The resource ID of the Key Vault for encryption. Required if keyManagementStorageAccounts is set to Customer.')
param encryptionKeyVaultResourceId string = ''

@description('Optional. Key management solution for storage accounts. Options: Platform, Customer.')
@allowed([
  'MicrosoftManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string = 'MicrosoftManaged'

@description('Optional. Log Analytics Workspace resource ID for Application Insights.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Private Link Scope resource ID for Application Insights.')
param privateLinkScopeResourceId string = ''

// ================================================================================================
// Function App Execution Parameters
// These parameters control the behavior and execution logic of the storage quota manager function.
// ================================================================================================
@description('Required. The resource id of the hostPool utilizing the FSLogix storage accounts. Used for tagging')
param hostPoolResourceId string

@description('Required. The resource id of the resource group containing the FSLogix storage accounts.')
param storageResourceGroupId string = ''

@description('Optional. Timer schedule for the function app (cron expression). Default is every 60 minutes.')
param timerSchedule string = '0 */60 * * * *'

// ========== //
// Variables  //
// ========== //

var deploymentSuffix = uniqueString(resourceGroup().id, deployment().name)
var storageSubscriptionId = split(storageResourceGroupId, '/')[2]
var storageResourceGroupName = split(storageResourceGroupId, '/')[4]
var hostPoolName = last(split(hostPoolResourceId, '/'))

var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : cloud
var locations = locationsObject[locationsEnvProperty]
var functionAppRegionAbbreviation = locations[location].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')
// Dynamically determine naming convention from existing host pool name
var nameConvReversed = startsWith(hostPoolName, resourceAbbreviations.hostPools)
  ? false // Resource type is at the beginning (e.g., "hp-avd-01")
  : endsWith(hostPoolName, resourceAbbreviations.hostPools)
      ? true // Resource type is at the end (e.g., "avd-01-hp")
      : false // Default fallback

var arrHostPoolName = split(hostPoolName, '-')
var lengthArrHostPoolName = length(arrHostPoolName)

var hpIdentifier = nameConvReversed
  ? lengthArrHostPoolName < 5 ? arrHostPoolName[0] : '${arrHostPoolName[0]}-${arrHostPoolName[1]}'
  : lengthArrHostPoolName < 5 ? arrHostPoolName[1] : '${arrHostPoolName[1]}-${arrHostPoolName[2]}'

var hpIndex = lengthArrHostPoolName == 3
  ? ''
  : nameConvReversed
      ? lengthArrHostPoolName < 5 ? arrHostPoolName[1] : arrHostPoolName[2]
      : lengthArrHostPoolName < 5 ? arrHostPoolName[2] : arrHostPoolName[3]

var hpBaseName = empty(hpIndex) ? hpIdentifier : '${hpIdentifier}-${hpIndex}'
var hpResPrfx = nameConvReversed ? hpBaseName : 'RESOURCETYPE-${hpBaseName}'

var nameConvSuffix = nameConvReversed ? 'LOCATION-RESOURCETYPE' : 'LOCATION'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvSuffix}'

// App Service Plan naming convention
var nameConv_Shared_Resources = nameConvReversed
  ? 'avd-TOKEN-${nameConvSuffix}'
  : 'RESOURCETYPE-avd-TOKEN-${nameConvSuffix}'
var appServicePlanName = replace(
  replace(
    replace(nameConv_Shared_Resources, 'RESOURCETYPE', resourceAbbreviations.appServicePlans),
    'LOCATION',
    functionAppRegionAbbreviation
  ),
  'TOKEN-',
  ''
)

// Generate unique identifiers for resource naming
var uniqueStringStorage = take(uniqueString(storageResourceGroupId, storageResourceGroupName), 6)

// Resource naming conventions for quota management
var appInsightsNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
  'LOCATION',
  functionAppRegionAbbreviation
)
var functionAppNameConv = replace(
  replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
  'LOCATION',
  functionAppRegionAbbreviation
)

// Private endpoint naming conventions
var privateEndpointNameConv = replace(
  nameConvReversed ? 'RESOURCE-SUBRESOURCE-VNETID-RESOURCETYPE' : 'RESOURCETYPE-RESOURCE-SUBRESOURCE-VNETID',
  'RESOURCETYPE',
  resourceAbbreviations.privateEndpoints
)
var privateEndpointNICNameConvTemp = nameConvReversed
  ? '${privateEndpointNameConv}-RESOURCETYPE'
  : 'RESOURCETYPE-${privateEndpointNameConv}'
var privateEndpointNICNameConv = replace(
  privateEndpointNICNameConvTemp,
  'RESOURCETYPE',
  resourceAbbreviations.networkInterfaces
)

// quota management resource names
var quotaManagementFAStorageAccountName = 'quotamanagement${uniqueStringStorage}'
var functionAppName = replace(functionAppNameConv, 'TOKEN-', 'quotamanagement-${uniqueStringStorage}-')
var storageAccountName = quotaManagementFAStorageAccountName
var appInsightsName = replace(appInsightsNameConv, 'TOKEN-', 'quotamanagement-${uniqueStringStorage}-')
var encryptionKeyName = '${hpBaseName}-encryption-key-${quotaManagementFAStorageAccountName}'

// ========== //
// Resources  //
// ========== //

// Conditional App Service Plan deployment
module hostingPlan '../../sharedModules/custom/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
  name: 'FunctionAppHostingPlan-${deploymentSuffix}'
  params: {
    functionAppKind: 'functionApp'
    hostingPlanType: 'FunctionsPremium'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_P0v3'
    tags: tags
    zoneRedundant: zoneRedundant
  }
}

// Storage Quota Manager Function App
module functionApp '../../sharedModules/custom/functionApp/functionApp.bicep' = {
  name: 'StorageQuotaFunctionApp-${deploymentSuffix}'
  params: {
    applicationInsightsName: appInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFilePrivateDnsZoneResourceId: azureFilePrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    azureQueuePrivateDnsZoneResourceId: azureQueuePrivateDnsZoneResourceId
    azureTablePrivateDnsZoneResourceId: azureTablePrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    encryptionKeyName: encryptionKeyName
    encryptionKeyVaultResourceId: encryptionKeyVaultResourceId
    functionAppAppSettings: [
      {
        name: 'ResourceGroupName'
        value: storageResourceGroupName
      }
      {
        name: 'SubscriptionId'
        value: storageSubscriptionId
      }
    ]
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    functionAppName: functionAppName
    hostPoolResourceId: hostPoolResourceId
    keyManagementStorageAccounts: keyManagementStorageAccounts
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    roleAssignments: [
      {
        roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
        scope: storageResourceGroupId
      }
    ]
    serverFarmId: empty(appServicePlanResourceId) ? hostingPlan!.outputs.hostingPlanId : appServicePlanResourceId
    storageAccountName: storageAccountName
    tags: tags
  }
}

// Storage Quota Manager Function
module storageQuotaFunction '../../sharedModules/custom/functionApp/function.bicep' = {
  name: 'StorageQuotaFunction-${deploymentSuffix}'
  params: {
    files: {
      'requirements.psd1': loadTextContent('functions/requirements.psd1')
      'run.ps1': loadTextContent('functions/run.ps1')
      '../profile.ps1': loadTextContent('functions/profile.ps1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'auto-increase-file-share-quota'
    schedule: timerSchedule
  }
}

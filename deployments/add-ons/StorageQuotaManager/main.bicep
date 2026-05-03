// FSLogix Storage Quota Manager Add-On
// Automated quota management for FSLogix Azure Files Premium file shares

targetScope = 'subscription'

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Common Parameters
// These parameters apply to the overall deployment and are shared across multiple resources.
// ================================================================================================

@description('Required. The location for all resources.')
param location string

@description('Required. Name of the resource group where the function app and its supporting resources are deployed. Defaults to the storage account resource group.')
param functionAppResourceGroupName string

@description('Optional. Tags for all resources.')
param tags object = {}

// ================================================================================================
// Brownfield Naming Override Parameters
// These parameters allow explicit control over resource naming for brownfield deployments where
// the existing host pool naming convention does not follow standard patterns. When specified,
// these override the automatic naming convention detection.
// ================================================================================================

@description('Optional. Explicit name for the Function App. If not provided, name is derived from host pool naming convention. Use this for brownfield deployments with non-standard host pool names. Must be globally unique and follow Azure naming rules (2-60 chars, alphanumeric and hyphens).')
@maxLength(60)
param functionAppNameOverride string = ''

@description('Optional. Explicit name for the Storage Account (used by Function App). If not provided, name is derived from host pool naming convention. Use this for brownfield deployments with non-standard host pool names. Must be globally unique, 3-24 chars, lowercase alphanumeric only.')
@maxLength(24)
param storageAccountNameOverride string = ''

@description('Optional. Explicit name for the storage encryption user-assigned identity. If not provided, name is derived from host pool naming convention. Use this for brownfield deployments where a CMK identity was previously created with a specific name. Must follow Azure naming rules (3-128 chars, alphanumeric, hyphens, underscores).')
@maxLength(128)
param storageEncryptionIdentityNameOverride string = ''

@description('Optional. Explicit name for the Application Insights instance. If not provided, name is derived from host pool naming convention. Use this for brownfield deployments with non-standard naming. Must follow Azure naming rules (1-260 chars, alphanumeric, hyphens, underscores, parentheses, periods).')
@maxLength(260)
param applicationInsightsNameOverride string = ''

// ================================================================================================
// Function App Infrastructure Parameters
// These parameters configure the Azure Function App infrastructure including networking, 
// security, encryption, and monitoring capabilities.
// ================================================================================================

@description('Optional. The resource ID of an existing App Service Plan for the function app. If not provided, a new plan will be deployed.')
param appServicePlanResourceId string = ''

@description('Optional. The name of the resource group to deploy the new App Service Plan into. Leave empty to deploy into the same resource group as the function app. Useful when sharing a single App Service Plan across multiple add-ons in a central operations resource group.')
param appServicePlanResourceGroupName string = ''

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
param azureFunctionAppPrivateDnsZoneResourceId string = ''

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
param storageResourceGroupId string

@description('Optional. Timer schedule for the function app (cron expression). Default is every 15 minutes.')
param timerSchedule string = '0 */15 * * * *'

// ========== //
// Variables  //
// ========== //

var deploymentSuffix = uniqueString(subscription().subscriptionId, functionAppResourceGroupName, deployment().name)
var aspResourceGroupName = empty(appServicePlanResourceGroupName) ? functionAppResourceGroupName : appServicePlanResourceGroupName
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
// Use explicit override if provided, otherwise derive from host pool naming convention
var appInsightsName = !empty(applicationInsightsNameOverride)
  ? applicationInsightsNameOverride
  : replace(
      replace(
        replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
        'LOCATION',
        functionAppRegionAbbreviation
      ),
      'TOKEN-',
      'sqm-${uniqueStringStorage}-'
    )

// Use explicit override if provided, otherwise derive from host pool naming convention
var functionAppName = !empty(functionAppNameOverride)
  ? functionAppNameOverride
  : replace(
      replace(
        replace(
          replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
          'LOCATION',
          functionAppRegionAbbreviation
        ),
        'TOKEN-',
        'sqm-${uniqueStringStorage}-'
      ),
      'LOCATION',
      functionAppRegionAbbreviation
    )

// Storage Account naming - use explicit override if provided, otherwise derive from naming convention
var storageAccountName = !empty(storageAccountNameOverride)
  ? toLower(storageAccountNameOverride)
  : toLower(replace(
      replace(
        replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', ''), 'LOCATION', functionAppRegionAbbreviation),
        'TOKEN-',
        'sqm-${uniqueStringStorage}'
      ),
      '-',
      ''
    ))

// Storage account name validation: Azure enforces 3-24 chars, lowercase alphanumeric only
// If the derived name fails validation, deployment will error at storage account module
// For brownfield deployments with non-standard host pool names, use storageAccountNameOverride parameter

var encryptionKeyName = '${hpBaseName}-encryption-key-${storageAccountName}'

// Use explicit override if provided, otherwise derive from host pool naming convention
var storageEncryptionIdentityName = !empty(storageEncryptionIdentityNameOverride)
  ? storageEncryptionIdentityNameOverride
  : replace(
      replace(
        replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
        'TOKEN-',
        'sqm-${uniqueStringStorage}-storage-encryption-'
      ),
      'LOCATION',
      functionAppRegionAbbreviation
    )

// ========== //
// Resources  //
// ========== //

// Conditional App Service Plan deployment
module hostingPlan '../../../.common/bicepModules/custom/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
  name: 'FunctionAppHostingPlan-${deploymentSuffix}'
  scope: resourceGroup(aspResourceGroupName)
  params: {
    functionAppKind: 'functionApp'
    hostingPlanType: 'FunctionsPremium'
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_P1v3'
    tags: tags
    zoneRedundant: zoneRedundant
  }
}

// Storage Quota Manager Function App
module functionApp '../../../.common/bicepModules/custom/functionApp/functionApp.bicep' = {
  name: 'StorageQuotaFunctionApp-${deploymentSuffix}'
  scope: resourceGroup(functionAppResourceGroupName)
  params: {
    applicationInsightsName: appInsightsName
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    enableQueueStorage: false
    enableTableStorage: false
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
    serverFarmId: empty(appServicePlanResourceId) ? hostingPlan!.outputs.hostingPlanId : appServicePlanResourceId
    storageAccountName: storageAccountName
    storageEncryptionIdentityName: storageEncryptionIdentityName
    tags: tags
  }
}

module roleAssignment_StorageAccounts '../../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  name: 'RA-StorageAccounts-${deploymentSuffix}'
  scope: resourceGroup(storageSubscriptionId, storageResourceGroupName)
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
    principalType: 'ServicePrincipal'
  }
}

// Storage Quota Manager Function
module storageQuotaFunction '../../../.common/bicepModules/custom/functionApp/function.bicep' = {
  name: 'StorageQuotaFunction-${deploymentSuffix}'
  scope: resourceGroup(functionAppResourceGroupName)
  params: {
    files: {
      'run.ps1': loadTextContent('functions/run.ps1')
      '../profile.ps1': '# Authentication is provided in the script'
      '../requirements.psd1': loadTextContent('functions/requirements.psd1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'auto-increase-file-share-quota'
    schedule: timerSchedule
  }
}

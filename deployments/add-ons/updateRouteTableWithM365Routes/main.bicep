// M365 Route Table Updater Add-On
// Keeps a route table current with Microsoft 365 IP ranges by downloading
// them periodically from the Microsoft 365 endpoint API and writing routes
// whose names start with 'M365-' into the target route table.
// All other routes in the table are left untouched.

targetScope = 'subscription'

// ========== //
// Parameters //
// ========== //

// ================================================================================================
// Common Parameters
// ================================================================================================

@description('Required. The location for all resources.')
param location string

@description('Required. Name of the resource group where the function app and its supporting resources will be deployed.')
param functionAppResourceGroupName string

@description('Optional. Tags for all resources.')
param tags object = {}

// ================================================================================================
// Brownfield Naming Override Parameters
// ================================================================================================

@description('Optional. Explicit name for the Function App. If not provided, derived from naming convention. Must be globally unique (2-60 chars, alphanumeric and hyphens).')
@maxLength(60)
param functionAppNameOverride string = ''

@description('Optional. Explicit name for the Storage Account used by the Function App. Must be globally unique, 3-24 chars, lowercase alphanumeric only.')
@maxLength(24)
param storageAccountNameOverride string = ''

@description('Optional. Explicit name for the storage encryption user-assigned identity. Must be 3-128 chars, alphanumeric, hyphens, underscores.')
@maxLength(128)
param storageEncryptionIdentityNameOverride string = ''

// ================================================================================================
// Function App Infrastructure Parameters
// ================================================================================================

@description('Optional. The resource ID of an existing App Service Plan. If not provided, a new Premium V3 P1v3 plan is deployed.')
param appServicePlanResourceId string = ''

@description('Optional. Resource group to deploy the App Service Plan into. Leave empty to deploy into the same RG as the function app.')
param appServicePlanResourceGroupName string = ''

@description('Optional. Enable zone redundancy for the App Service Plan (only when deploying a new plan).')
param zoneRedundant bool = false

@description('Optional. Enable private endpoints for the function app and its storage account.')
param privateEndpoint bool = false

@description('Optional. Subnet resource ID for private endpoints. Required when privateEndpoint is true.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. Subnet resource ID for function app VNet integration. Required when privateEndpoint is true.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Optional. Private DNS Zone resource ID for blob storage (privatelink.blob.core.windows.net).')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Optional. Private DNS Zone resource ID for function app (privatelink.azurewebsites.net).')
param azureFunctionAppPrivateDnsZoneResourceId string = ''

@description('Optional. Array of permitted IP addresses or CIDR blocks for the function app storage firewall.')
param permittedIPs array = []

@description('Optional. Resource ID of the Key Vault for storage encryption. Required when keyManagementStorageAccounts is CustomerManaged.')
param encryptionKeyVaultResourceId string = ''

@description('Optional. Storage account key management mode.')
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string = 'PlatformManaged'

@description('Optional. Log Analytics Workspace resource ID for Application Insights.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Private Link Scope resource ID for Application Insights.')
param privateLinkScopeResourceId string = ''

// ================================================================================================
// Function App Execution Parameters
// ================================================================================================

@description('Required. Resource ID of the Azure Route Table to manage. The function app managed identity receives Network Contributor on its resource group.')
param routeTableResourceId string

@description('Optional. Microsoft 365 endpoint instance to download IP ranges from.')
@allowed([
  'worldwide'
  'china'
  'usgovdod'
  'usgovgcchigh'
])
param m365EndpointInstance string = 'worldwide'

@description('Optional. Timer schedule in NCrontab format ({second} {minute} {hour} {day} {month} {day-of-week}). Default runs every 8 hours at minute 0.')
param timerSchedule string = '0 0 */8 * * *'

// ========== //
// Variables  //
// ========== //

var deploymentSuffix = uniqueString(subscription().subscriptionId, functionAppResourceGroupName, deployment().name)
var aspResourceGroupName = empty(appServicePlanResourceGroupName) ? functionAppResourceGroupName : appServicePlanResourceGroupName

var routeTableSubscriptionId    = split(routeTableResourceId, '/')[2]
var routeTableResourceGroupName = split(routeTableResourceId, '/')[4]

var cloud                 = toLower(environment().name)
var locationsObject       = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty  = startsWith(cloud, 'us') ? 'other' : cloud
var locations             = locationsObject[locationsEnvProperty]
var functionAppRegionAbbr = locations[location].abbreviation
var resourceAbbreviations = loadJsonContent('../../../.common/data/resourceAbbreviations.json')

// ============================================================================
// Naming Convention
// Derive convention from the route table resource ID (no host pool available).
// Uses 'urt' (update route table) as the fixed base token when no host pool
// is provided, following the same pattern as storageQuotaManager (sqm).
// ============================================================================
var uniqueStringUrt = take(uniqueString(routeTableSubscriptionId, routeTableResourceGroupName), 6)

// Detect RT-first vs RT-last from the function app resource group name as a fallback.
// Since we have no host pool, we use a simplified naming approach with 'urt' as the base.
var nameConvReversed = false  // Default to RT-first (CAF standard)
var hpResPrfx        = 'RESOURCETYPE-urt'
var nameConvSuffix   = 'LOCATION'
var nameConv_HP_Resources = '${hpResPrfx}-TOKEN-${nameConvSuffix}'

var appServicePlanName = nameConvReversed
  ? 'urt-${functionAppRegionAbbr}-${resourceAbbreviations.appServicePlans}'
  : '${resourceAbbreviations.appServicePlans}-urt-${functionAppRegionAbbr}'

// Private endpoint naming
var privateEndpointNameConv = nameConvReversed
  ? 'RESOURCE-SUBRESOURCE-VNETID-${resourceAbbreviations.privateEndpoints}'
  : '${resourceAbbreviations.privateEndpoints}-RESOURCE-SUBRESOURCE-VNETID'
var privateEndpointNICNameConvTemp = nameConvReversed
  ? '${privateEndpointNameConv}-${resourceAbbreviations.networkInterfaces}'
  : '${resourceAbbreviations.networkInterfaces}-${privateEndpointNameConv}'
var privateEndpointNICNameConv = privateEndpointNICNameConvTemp

// Function app name
var functionAppName = !empty(functionAppNameOverride)
  ? functionAppNameOverride
  : replace(
      replace(
        replace(
          replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.functionApps),
          'LOCATION',
          functionAppRegionAbbr
        ),
        'TOKEN-',
        'urt-${uniqueStringUrt}-'
      ),
      'LOCATION',
      functionAppRegionAbbr
    )

// Storage account name
var storageAccountName = !empty(storageAccountNameOverride)
  ? toLower(storageAccountNameOverride)
  : toLower(replace(
      replace(
        replace(replace(nameConv_HP_Resources, 'RESOURCETYPE', ''), 'LOCATION', functionAppRegionAbbr),
        'TOKEN-',
        'urt${uniqueStringUrt}'
      ),
      '-',
      ''
    ))

var encryptionKeyName = 'encryption-key-${storageAccountName}'

var storageEncryptionIdentityName = !empty(storageEncryptionIdentityNameOverride)
  ? storageEncryptionIdentityNameOverride
  : replace(
      replace(
        replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.userAssignedIdentities),
        'TOKEN-',
        'urt-${uniqueStringUrt}-storage-encryption-'
      ),
      'LOCATION',
      functionAppRegionAbbr
    )

// ========== //
// Resources  //
// ========== //

// Conditional App Service Plan
module hostingPlan '../../../.common/bicepModules/custom/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
  name: 'UrtHostingPlan-${deploymentSuffix}'
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

// M365 Route Updater Function App
module functionApp '../../../.common/bicepModules/custom/functionApp/functionApp.bicep' = {
  name: 'UrtFunctionApp-${deploymentSuffix}'
  scope: resourceGroup(functionAppResourceGroupName)
  params: {
    applicationInsightsName: replace(
      replace(nameConv_HP_Resources, 'RESOURCETYPE', resourceAbbreviations.applicationInsights),
      'TOKEN-',
      'urt-${uniqueStringUrt}-'
    )
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
        name: 'RouteTableResourceId'
        value: routeTableResourceId
      }
      {
        name: 'M365EndpointInstance'
        value: m365EndpointInstance
      }
    ]
    functionAppDelegatedSubnetResourceId: functionAppDelegatedSubnetResourceId
    functionAppName: functionAppName
    hostPoolResourceId: ''
    keyManagementStorageAccounts: keyManagementStorageAccounts
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    permittedIPs: permittedIPs
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

// Grant the function app managed identity Network Contributor on the route table resource group.
// This allows the function to read and write the route table via the Azure REST API.
// Scope is limited to the route table's resource group, not the whole subscription.
module roleAssignment_RouteTableRg '../../../.common/bicepModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  name: 'RA-RouteTable-NetworkContributor-${deploymentSuffix}'
  scope: resourceGroup(routeTableSubscriptionId, routeTableResourceGroupName)
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    roleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
    principalType: 'ServicePrincipal'
  }
}

// Deploy the function code
module urtFunction '../../../.common/bicepModules/custom/functionApp/function.bicep' = {
  name: 'UrtFunction-${deploymentSuffix}'
  scope: resourceGroup(functionAppResourceGroupName)
  params: {
    files: {
      'run.ps1': loadTextContent('functions/run.ps1')
      '../profile.ps1': '# Authentication handled in run.ps1 via managed identity REST API.'
      '../requirements.psd1': loadTextContent('functions/requirements.psd1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'update-m365-routes'
    schedule: timerSchedule
  }
}

// ======= //
// Outputs //
// ======= //

@description('Name of the deployed Function App.')
output functionAppName string = functionApp.outputs.functionAppName

@description('Principal ID of the Function App managed identity.')
output functionAppPrincipalId string = functionApp.outputs.functionAppPrincipalId

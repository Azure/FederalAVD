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
// Naming Convention Parameters
// These parameters control how infrastructure resource names are computed. When associated with
// a host pool deployed by this solution, the naming convention is automatically populated from
// the hpNamingConvention tag on the host pool.
// ================================================================================================

@description('''Naming convention controlling how Function App infrastructure resources are named.
Should match the convention used when deploying the host pool. Pre-populated from the
hpNamingConvention tag on the host pool resource.''')
param namingConvention object = {
  components: ['resourceType', 'workload', 'purpose', 'location']
  delimiter: '-'
  workload: 'avd'
}

@description('Optional. The host pool base name / identifier used for naming (e.g. desktop-01). Pre-populated from the hpIdentifier tag on the host pool resource. When empty, falls back to sqm.')
param identifier string = ''

@description('Optional. Overrides for resource type abbreviations used when computing infrastructure resource names. Only the keys you provide are overridden; all others use CAF defaults. Supported keys: functionApps, appServicePlans, userAssignedIdentities, privateEndpoints, networkInterfaces.')
param namingResourceTypeCodes object = {}

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

@description('Optional. Explicit name for the App Service Plan. If not provided, name is derived from the naming convention. Use this for brownfield deployments where an existing plan was created with a non-standard name. Must follow Azure naming rules (1-40 chars, alphanumeric and hyphens).')
@maxLength(40)
param appServicePlanNameOverride string = ''


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
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string = 'PlatformManaged'

@description('Optional. Array of permitted IP addresses or CIDR blocks for the function app storage account firewall. Use when managing from a trusted workstation outside the Azure network boundary.')
param permittedIPs array = []



// ================================================================================================
// Function App Execution Parameters
// These parameters control the behavior and execution logic of the storage quota manager function.
// ================================================================================================
@description('Optional. The resource id of the hostPool utilizing the FSLogix storage accounts. Used for tagging and naming convention detection. Leave empty for non-host pool storage scenarios (e.g., App Attach). When empty, custom naming overrides must be provided.')
param hostPoolResourceId string = ''

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

var cloud = toLower(environment().name)
var locationsObject = loadJsonContent('../../../.common/data/locations.json')
var locationsEnvProperty = startsWith(cloud, 'us') ? 'other' : cloud
var locations = locationsObject[locationsEnvProperty]
var locationForLookup = startsWith(cloud, 'us') ? substring(location, 5, max(length(location) - 5, 0)) : location
var functionAppRegionAbbreviation = locations[locationForLookup].abbreviation

// ── Naming convention ─────────────────────────────────────────────────────────
var uniqueStringStorage = take(uniqueString(storageSubscriptionId, storageResourceGroupName), 6)
var effectiveIdentifier = !empty(identifier) ? identifier : 'sqm'
var effectiveNamingConvention = !empty(namingResourceTypeCodes) ? union(namingConvention, { resourceTypeCodes: namingResourceTypeCodes }) : namingConvention

module sqmNaming './modules/naming.bicep' = {
  name: 'SQM-Naming-${deploymentSuffix}'
  params: {
    namingConvention: effectiveNamingConvention
    identifier: effectiveIdentifier
    locationAbbreviation: functionAppRegionAbbreviation
    uniqueString: uniqueStringStorage
  }
}

var appServicePlanName         = !empty(appServicePlanNameOverride) ? appServicePlanNameOverride : sqmNaming.outputs.appServicePlanName
var privateEndpointNameConv    = sqmNaming.outputs.privateEndpointNameConv
var privateEndpointNICNameConv = sqmNaming.outputs.privateEndpointNICNameConv

var functionAppName               = !empty(functionAppNameOverride)               ? functionAppNameOverride               : sqmNaming.outputs.functionAppName
var storageAccountName            = !empty(storageAccountNameOverride)            ? toLower(storageAccountNameOverride)   : sqmNaming.outputs.storageAccountName
var storageEncryptionIdentityName = !empty(storageEncryptionIdentityNameOverride) ? storageEncryptionIdentityNameOverride : sqmNaming.outputs.storageEncryptionIdentityName
var encryptionKeyName             = '${effectiveIdentifier}-encryption-key-${storageAccountName}'

// ========== //
// Resources  //
// ========== //

// Conditional App Service Plan deployment
module hostingPlan '../../sharedModules/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
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
module functionApp '../../sharedModules/functionApp/functionApp.bicep' = {
  name: 'StorageQuotaFunctionApp-${deploymentSuffix}'
  scope: resourceGroup(functionAppResourceGroupName)
  params: {
    azureBlobPrivateDnsZoneResourceId: azureBlobPrivateDnsZoneResourceId
    azureFunctionAppPrivateDnsZoneResourceId: azureFunctionAppPrivateDnsZoneResourceId
    deploymentSuffix: deploymentSuffix
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
    privateEndpoint: privateEndpoint
    privateEndpointNameConv: privateEndpointNameConv
    privateEndpointNICNameConv: privateEndpointNICNameConv
    privateEndpointSubnetResourceId: privateEndpointSubnetResourceId
    serverFarmId: empty(appServicePlanResourceId) ? hostingPlan!.outputs.hostingPlanId : appServicePlanResourceId
    storageAccountName: storageAccountName
    storageEncryptionIdentityName: storageEncryptionIdentityName
    permittedIPs: permittedIPs
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
module storageQuotaFunction '../../sharedModules/functionApp/function.bicep' = {
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

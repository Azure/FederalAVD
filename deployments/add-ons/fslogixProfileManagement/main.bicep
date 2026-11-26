targetScope = 'subscription'

@description('Required. Complete name for the Application Insights resource.')
@minLength(1)
@maxLength(260)
param applicationInsightsName string

@description('Optional. The name for a new App Service plan. Ignored when using an existing plan ID.')
@maxLength(40)
param appServicePlanName string = ''

@description('Optional. Existing same-region Windows Dedicated App Service plan ID. Empty creates a dedicated PremiumV3_P0v3 plan.')
param appServicePlanResourceId string = ''

@description('Optional. The SKU for a new App Service plan. Ignored when using an existing plan ID.')
@allowed([
  'P0v3'
  'P1v3'
  'P2v3'
  'P3v3'
])
param appServicePlanSku string = 'P0v3'

@description('Required for private mode. Existing target-cloud blob private DNS zone ID, linked to the integration VNet.')
param azureBlobPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Function App private DNS zone ID, linked to the integration VNet.')
param azureFunctionAppPrivateDnsZoneResourceId string = ''

@description('Required for private mode. Existing target-cloud Key Vault private DNS zone ID, linked to the integration VNet.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''

@description('Optional. The number of days after which FSLogix profile containers should be deleted.')
@minValue(1)
@maxValue(365)
param deleteOlderThanDays int = 60

@description('Optional. Endpoint type for the PaaS services.')
@allowed([
  'private'
  'public'
  'service'
])
param endpointType string = 'private'

@description('Optional. Resource ID for the delegated subnet used for outbound connectivity from the function app.')
param functionAppDelegatedSubnetResourceId string = ''

@description('Required. Name for the Function App.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('Required. Name for the Key Vault used for customer managed keys.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Optional. Azure region for the resource group and resources.')
param location string = deployment().location

@description('Optional. Existing workspace ID. Nonempty enables Application Insights and FunctionAppLogs diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Existing Azure Monitor Private Link Scope ID. Without it, enabled Insights uses public ingestion and query endpoints.')
param privateLinkScopeResourceId string = ''

@description('Required. Name for the resource group.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Required. Timer schedule in six-field Functions NCRONTAB format.')
@minLength(11)
param schedule string = '0 0 21 * * *'

@description('Required. Name for the storage account.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Optional. Resource ID of the subnet for either the service or private endpoint.')
param subnetResourceId string = ''

@description('Required. List of subscription IDs for managing Azure Files shares with FSLogix profile containers.')
@minLength(1)
param subscriptionIds array

@description('Optional. Metadata stored as key / value pairs on the resource group and resources.')
param tags object = {}

@description('Optional. Time zone for the timer schedule in the Function App.')
@allowed([
  'Central Standard Time'
  'Eastern Standard Time'
  'Mountain Standard Time'
  'Pacific Standard Time'
  'UTC'
])
param timeZone string = 'UTC'

@description('Required. Name for the User-Assigned managed identity.')
@minLength(3)
@maxLength(128)
param userAssignedIdentityName string

var integrationSubnetId = contains(['private', 'service'], endpointType) && empty(trim(functionAppDelegatedSubnetResourceId))
  ? fail('Private and service modes require functionAppDelegatedSubnetResourceId.')
  : functionAppDelegatedSubnetResourceId
var blobDnsZoneId = endpointType == 'private' && empty(trim(azureBlobPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureBlobPrivateDnsZoneResourceId.')
  : azureBlobPrivateDnsZoneResourceId
var appDnsZoneId = endpointType == 'private' && empty(trim(azureFunctionAppPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureFunctionAppPrivateDnsZoneResourceId.')
  : azureFunctionAppPrivateDnsZoneResourceId
var vaultDnsZoneId = endpointType == 'private' && empty(trim(azureKeyVaultPrivateDnsZoneResourceId))
  ? fail('Private mode requires azureKeyVaultPrivateDnsZoneResourceId.')
  : azureKeyVaultPrivateDnsZoneResourceId

resource rg 'Microsoft.Resources/resourceGroups@2019-10-01'  = {
  name: resourceGroupName
  location: location
  tags: tags
}

module keyVault '../../shared/modules/resourceModules/keyVault/vaults/deploy.bicep' = {
  scope: rg
  params: {
    location: location
    name: keyVaultName
    networkAcls: endpointType == 'service'
      ? {
          bypass: 'AzureServices'
          defaultAction: 'Deny'
          ipRules: []
          virtualNetworkRules: [
            {
              id: subnetResourceId
              ignoreMissingVnetServiceEndpoint: false
            }
          ]
        }
      : {}
    publicNetworkAccess: endpointType == 'private' ? 'Disabled' : 'Enabled'
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
  }
}

module keyVaultPrivateEndpoint '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (endpointType == 'private') {
  scope: rg
  params: {
    groupId: 'vault'
    location: location
    name: 'pe-${keyVaultName}'
    privateDNSZoneIds: [
      vaultDnsZoneId
    ]
    privateLinkServiceId: keyVault!.outputs.resourceId
    subnetResourceId: subnetResourceId
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  }
}

module keys '../../shared/modules/orchestration/customerManagedKeys/customerManagedKeys.bicep' = {
  scope: rg
  params: {
    keyVaultResourceId: keyVault.outputs.resourceId
    keyManagementType: 'CustomerManagedHSM'
    keyNames: [storageAccountName]
    identityName: userAssignedIdentityName
    location: location
    tags: tags
  }
}

module serverFarm '../../shared/modules/resourceModules/functionApp/functionAppHostingPlan.bicep' = if (empty(appServicePlanResourceId)) {
  scope: rg
  params: {
    functionAppKind: 'functionapp'
    hostingPlanType: 'Dedicated'
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_${appServicePlanSku}'
    tags: tags
    zoneRedundant: false
  }
}

module functionApp '../../shared/modules/resourceModules/functionApp/functionApp.bicep' = {
  scope: rg
  params: {
    applicationInsightsName: applicationInsightsName
    azureBlobPrivateDnsZoneResourceId: blobDnsZoneId
    azureFunctionAppPrivateDnsZoneResourceId: appDnsZoneId
    enableApplicationInsights: !empty(logAnalyticsWorkspaceResourceId)
    enableQueueStorage: false
    enableTableStorage: false
    encryptionKeyName: storageAccountName
    encryptionKeyVaultResourceId: keyVault.outputs.resourceId
    functionAppAppSettings: [
      {
        name: 'AzureFunctionsJobHost__functionTimeout'
        value: '01:30:00'
      }
      {
        name: 'WEBSITE_TIME_ZONE'
        value: timeZone
      }
      {
        name: 'Cloud'
        value: environment().name
      }
      {
        name: 'DeleteOlderThanDays'
        value: string(deleteOlderThanDays)
      }
      {
        name: 'ResourceManagerUrl'
        value: environment().resourceManager
      }
      {
        name: 'SubscriptionIds'
        value: join(subscriptionIds, ',')
      }
    ]
    functionAppDelegatedSubnetResourceId: integrationSubnetId
    functionAppName: functionAppName
    hostPoolResourceId: ''
    keyManagementStorageAccounts: 'CustomerManagedHSM'
    location: location
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    paasPublicNetworkAccess: endpointType == 'private'
      ? 'Disabled'
      : endpointType == 'service'
        ? 'EnabledWithRestrictions'
        : 'Enabled'
    privateEndpoint: endpointType == 'private' ? true : false
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-pe-RESOURCE-SUBRESOURCE'
    privateEndpointSubnetResourceId: subnetResourceId
    privateLinkScopeResourceId: privateLinkScopeResourceId
    serverFarmId: empty(appServicePlanResourceId) ? serverFarm!.outputs.hostingPlanId : appServicePlanResourceId
    storageAccountName: storageAccountName
    storageEncryptionIdentityName: userAssignedIdentityName
    tags: tags
  }
  dependsOn: [
    keys
  ]
}

// Gives the function app rights to read the subscriptions
module roleAssignmentReader '../../shared/modules/resourceModules/authorization/roleAssignments/subscription/deploy.bicep' = [for subscriptionId in subscriptionIds: {
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  }
}]

// Gives the function app rights to access Azure Files shares
module roleAssignmentStorageFileDataPrivilegedContributor '../../shared/modules/resourceModules/authorization/roleAssignments/subscription/deploy.bicep' = [for subscriptionId in subscriptionIds: {
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: '69566ab7-960f-475b-8e7c-b3118f30c6bd' // Storage File Data Privileged Contributor
  }
}]

module function '../../shared/modules/resourceModules/functionApp/function.bicep' = {
  scope: rg
  params: {
    files: {
      'requirements.psd1': loadTextContent('scripts/requirements.psd1')
      'run.ps1': loadTextContent('scripts/run.ps1')
      '../profile.ps1': loadTextContent('scripts/profile.ps1')
    }
    functionAppName: functionApp.outputs.functionAppName
    functionName: 'FsLogixProfileManagement'
    schedule: schedule
  }
}

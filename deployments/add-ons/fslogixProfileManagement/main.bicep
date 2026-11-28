targetScope = 'subscription'

import { servicePublicNetworkAccessMode, resolveNetworkAccess, serviceEndpointSubnetIds } from '../../shared/modules/orchestration/networking/functions.bicep'



@description('Optional. Allowed runtime-storage subnet IDs with existing Storage service endpoints. Does not change consumed profile storage or subnets.')
param storageServiceEndpointSubnetResourceIds string[] = []

@description('Optional. Allowed encryption-vault subnet IDs with existing Microsoft.KeyVault service endpoints. Does not modify subnets.')
param keyVaultServiceEndpointSubnetResourceIds string[] = []

@description('Optional. Allowed Function App inbound subnet IDs with existing Microsoft.Web service endpoints. Independent of outbound VNet integration.')
param functionAppServiceEndpointSubnetResourceIds string[] = []

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

@description('Required when storagePrivateEndpoint is true. Existing target-cloud blob private DNS zone ID, linked to the integration VNet.')
param blobPrivateDnsZoneResourceId string = ''

@description('Required when functionAppPrivateEndpoint is true. Existing target-cloud Function App private DNS zone ID, linked to the integration VNet.')
param websitesPrivateDnsZoneResourceId string = ''

@description('Required when keyVaultPrivateEndpoint is true. Existing target-cloud Key Vault private DNS zone ID, linked to the integration VNet.')
param vaultPrivateDnsZoneResourceId string = ''

@description('Optional. The number of days after which FSLogix profile containers should be deleted.')
@minValue(1)
@maxValue(2555)
param deleteOlderThanDays int = 60


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

@description('Optional. Public endpoint policy for newly created storage resources. Independent of private endpoints and other service families.')
param storagePublicNetworkAccess servicePublicNetworkAccessMode = 'Disabled'

@description('Optional. Public IP addresses/CIDRs allowed for newly created storage resources. Retained in all access modes; does not grant authorization.')
param storagePermittedIPs string[] = []

@description('Optional. Deploy private endpoints for newly created storage resources. Does not set the public endpoint policy.')
param storagePrivateEndpoint bool = true

@description('Conditional. Existing private endpoint subnet resource ID; required when storagePrivateEndpoint is true. Does not modify the subnet.')
param storagePrivateEndpointSubnetResourceId string = ''

@description('Optional. Public endpoint policy for newly created keyVault resources. Independent of private endpoints and other service families.')
param keyVaultPublicNetworkAccess servicePublicNetworkAccessMode = 'Disabled'

@description('Optional. Public IP addresses/CIDRs allowed for newly created keyVault resources. Retained in all access modes; does not grant authorization.')
param keyVaultPermittedIPs string[] = []

@description('Optional. Deploy private endpoints for newly created keyVault resources. Does not set the public endpoint policy.')
param keyVaultPrivateEndpoint bool = true

@description('Conditional. Existing private endpoint subnet resource ID; required when keyVaultPrivateEndpoint is true. Does not modify the subnet.')
param keyVaultPrivateEndpointSubnetResourceId string = ''

@description('Optional. Public endpoint policy for newly created functionApp resources. Independent of private endpoints and other service families.')
param functionAppPublicNetworkAccess servicePublicNetworkAccessMode = 'Disabled'

@description('Optional. Public IP addresses/CIDRs allowed for newly created functionApp resources. Retained in all access modes; does not grant authorization.')
param functionAppPermittedIPs string[] = []

@description('Optional. Deploy private endpoints for newly created functionApp resources. Does not set the public endpoint policy.')
param functionAppPrivateEndpoint bool = true

@description('Conditional. Existing private endpoint subnet resource ID; required when functionAppPrivateEndpoint is true. Does not modify the subnet.')
param functionAppPrivateEndpointSubnetResourceId string = ''

var integrationSubnetId = functionAppDelegatedSubnetResourceId
var effectiveKeyVaultPermittedIPs = filter(keyVaultPermittedIPs, ip => !empty(trim(ip)))
var keyVaultSubnetIds = serviceEndpointSubnetIds(keyVaultServiceEndpointSubnetResourceIds)
var keyVaultNetworkAccess = resolveNetworkAccess(keyVaultPublicNetworkAccess, keyVaultPrivateEndpoint, !empty(effectiveKeyVaultPermittedIPs) || !empty(keyVaultSubnetIds))
var keyVaultNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: keyVaultNetworkAccess.defaultAction
  ipRules: map(effectiveKeyVaultPermittedIPs, ip => { value: endsWith(trim(ip), '/32') ? replace(trim(ip), '/32', '') : trim(ip) })
  virtualNetworkRules: map(keyVaultSubnetIds, id => { id: id, ignoreMissingVnetServiceEndpoint: false })
}
var blobDnsZoneId = storagePrivateEndpoint && empty(trim(blobPrivateDnsZoneResourceId))
  ? fail('storagePrivateEndpoint requires blobPrivateDnsZoneResourceId.')
  : blobPrivateDnsZoneResourceId
var appDnsZoneId = functionAppPrivateEndpoint && empty(trim(websitesPrivateDnsZoneResourceId))
  ? fail('functionAppPrivateEndpoint requires websitesPrivateDnsZoneResourceId.')
  : websitesPrivateDnsZoneResourceId
var vaultDnsZoneId = keyVaultPrivateEndpoint && empty(trim(vaultPrivateDnsZoneResourceId))
  ? fail('keyVaultPrivateEndpoint requires vaultPrivateDnsZoneResourceId.')
  : vaultPrivateDnsZoneResourceId

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
    networkAcls: keyVaultNetworkAcls
    publicNetworkAccess: keyVaultNetworkAccess.publicNetworkAccess
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
  }
}

module keyVaultPrivateEndpointDeployment '../../shared/modules/resourceModules/network/privateEndpoints/deploy.bicep' = if (keyVaultPrivateEndpoint) {
  scope: rg
  params: {
    groupId: 'vault'
    location: location
    name: 'pe-${keyVaultName}'
    privateDNSZoneIds: [
      vaultDnsZoneId
    ]
    privateLinkServiceId: keyVault!.outputs.resourceId
    subnetResourceId: keyVaultPrivateEndpointSubnetResourceId
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

module serverFarm '../../shared/modules/resourceModules/web/serverfarms/deploy.bicep' = if (empty(appServicePlanResourceId)) {
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

module functionApp '../../shared/modules/orchestration/functionApp/functionApp.bicep' = {
  scope: rg
  params: {
    applicationInsightsName: applicationInsightsName
    blobPrivateDnsZoneResourceId: blobDnsZoneId
    websitesPrivateDnsZoneResourceId: appDnsZoneId
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
    storagePublicNetworkAccess: storagePublicNetworkAccess
    functionAppPublicNetworkAccess: functionAppPublicNetworkAccess
    storagePermittedIPs: storagePermittedIPs
    functionAppPermittedIPs: functionAppPermittedIPs
    storageServiceEndpointSubnetResourceIds: storageServiceEndpointSubnetResourceIds
    functionAppServiceEndpointSubnetResourceIds: functionAppServiceEndpointSubnetResourceIds
    storagePrivateEndpoint: storagePrivateEndpoint
    functionAppPrivateEndpoint: functionAppPrivateEndpoint
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-pe-RESOURCE-SUBRESOURCE'
    storagePrivateEndpointSubnetResourceId: storagePrivateEndpointSubnetResourceId
    functionAppPrivateEndpointSubnetResourceId: functionAppPrivateEndpointSubnetResourceId
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
  scope: subscription(subscriptionId)
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  }
}]

// Gives the function app rights to access Azure Files shares
module roleAssignmentStorageFileDataPrivilegedContributor '../../shared/modules/resourceModules/authorization/roleAssignments/subscription/deploy.bicep' = [for subscriptionId in subscriptionIds: {
  scope: subscription(subscriptionId)
  params: {
    principalId: functionApp.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: '69566ab7-960f-475b-8e7c-b3118f30c6bd' // Storage File Data Privileged Contributor
  }
}]

module function '../../shared/modules/resourceModules/web/sites/functions/deploy.bicep' = {
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

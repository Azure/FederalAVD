param applicationInsightsName string
param azureBlobPrivateDnsZoneResourceId string
param azureFilePrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
param functionAppDelegatedSubnetResourceId string
param enableApplicationInsights bool
param encryptionKeyName string
param encryptionKeyVaultUri string
param encryptionUserAssignedIdentityResourceId string
param functionAppName string
param functionAppAppSettings array
param hostPoolResourceId string
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceResourceId string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param privateLinkScopeResourceId string
param resourceGroupRoleAssignments array = []
param serverFarmId string
param storageAccountName string
param tags object
param timeStamp string

var cloudSuffix = replace(replace(environment().resourceManager, 'https://management.', ''), '/', '')
// ensure that private endpoint name and nic name are not longer than 80
var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var peVnetId = length(privateEndpointVnetName) < 37
  ? privateEndpointVnetName
  : uniqueString(privateEndpointVnetName)

var azureStoragePrivateDnsZoneResourceIds = [
  azureBlobPrivateDnsZoneResourceId
  azureFilePrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
  azureTablePrivateDnsZoneResourceId
]

var storageSubResources = [
  'blob'
  'file'
  'queue'
  'table'
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: keyManagementStorageAccounts != 'MicrosoftManaged'
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${encryptionUserAssignedIdentityResourceId}': {}
        }
      }
    : null
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
    allowSharedKeyAccess: false
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'None'
    }
    defaultToOAuthAuthentication: false
    dnsEndpointType: 'Standard'
    encryption: {
      identity: keyManagementStorageAccounts != 'MicrosoftManaged'
        ? {
            userAssignedIdentity: encryptionUserAssignedIdentityResourceId
          }
        : null
      keySource: keyManagementStorageAccounts != 'MicrosoftManaged' ? 'Microsoft.KeyVault' : 'Microsoft.Storage'
      keyvaultproperties: keyManagementStorageAccounts != 'MicrosoftManaged'
        ? {
            keyvaulturi: encryptionKeyVaultUri
            keyname: encryptionKeyName
          }
        : null
      requireInfrastructureEncryption: true
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        table: {
          keyType: 'Account'
          enabled: true
        }
        queue: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
    }
    largeFileSharesState: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
      defaultAction: privateEndpoint ? 'Deny' : 'Allow'
    }
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    sasPolicy: {
      expirationAction: 'Log'
      sasExpirationPeriod: '180.00:00:00'
    }
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-09-01' = {
  parent: storageAccount
  name: 'default'
}

resource privateEndpoints_storage 'Microsoft.Network/privateEndpoints@2023-04-01' = [
  for subResource in storageSubResources: if (privateEndpoint) {
    name: replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', subResource), 'RESOURCE', storageAccountName),
      'VNETID',
      peVnetId
    )
    location: location
    properties: {
      customNetworkInterfaceName: replace(
        replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', subResource), 'RESOURCE', storageAccountName),
        'VNETID',
        peVnetId
      )
      privateLinkServiceConnections: [
        {
          name: replace(
            replace(replace(privateEndpointNameConv, 'SUBRESOURCE', subResource), 'RESOURCE', storageAccountName),
            'VNETID',
            peVnetId
          )
          properties: {
            privateLinkServiceId: storageAccount.id
            groupIds: [
              subResource
            ]
          }
        }
      ]
      subnet: {
        id: privateEndpointSubnetResourceId
      }
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
  }
]

resource privateDnsZoneGroups_storage 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-08-01' = [
  for i in range(0, length(azureStoragePrivateDnsZoneResourceIds) - 1): if(privateEndpoint && !empty(azureStoragePrivateDnsZoneResourceIds[i])) {
    parent: privateEndpoints_storage[i]
    name: storageAccount.name
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'ipconfig1'
          properties: {
            #disable-next-line use-resource-id-functions
            privateDnsZoneId: azureStoragePrivateDnsZoneResourceIds[i]
          }
        }
      ]
    }
  }
]

resource diagnosticSetting_storage_blob 'Microsoft.Insights/diagnosticsettings@2017-05-01-preview' = if (enableApplicationInsights) {
  scope: blobService
  name: '${storageAccountName}-blob-diagnosticSettings'
  properties: {
    logs: [
      {
        category: 'StorageWrite'
        enabled: true
      }
    ]
    #disable-next-line BCP037
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspaceResourceId
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = if (enableApplicationInsights) {
  name: applicationInsightsName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Insights/components'] ?? {})
  properties: {
    Application_Type: 'web'
    publicNetworkAccessForIngestion: privateEndpoint ? 'Disabled' : null
    publicNetworkAccessForQuery: privateEndpoint ? 'Disabled' : null
    WorkspaceResourceId: logAnalyticsWorkspaceResourceId
  }
  kind: 'web'
}

module updatePrivateLinkScope '../privateLinkScopes/get-PrivateLinkScope.bicep' = if (enableApplicationInsights && !empty(privateLinkScopeResourceId)) {
  name: 'PrivateLlinkScope-${timeStamp}'
  scope: subscription()
  params: {
    privateLinkScopeResourceId: privateLinkScopeResourceId
    scopedResourceIds: [
      applicationInsights.id
    ]
    timeStamp: timeStamp
  }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Web/sites'] ?? {})
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    clientAffinityEnabled: false
    httpsOnly: true
    publicNetworkAccess: privateEndpoint ? 'Disabled' : null
    serverFarmId: serverFarmId
    siteConfig: {
      alwaysOn: true
      appSettings: union(
        [
          {
            name: 'AzureWebJobsStorage__blobServiceUri'
            value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}'
          }
          {
            name: 'AzureWebJobsStorage__credential'
            value: 'managedidentity'
          }
          {
            name: 'AzureWebJobsStorage__queueServiceUri'
            value: 'https://${storageAccount.name}.queue.${environment().suffixes.storage}'
          }
          {
            name: 'AzureWebJobsStorage__tableServiceUri'
            value: 'https://${storageAccount.name}.table.${environment().suffixes.storage}'
          }
          {
            name: 'FUNCTIONS_EXTENSION_VERSION'
            value: '~4'
          }
          {
            name: 'FUNCTIONS_WORKER_RUNTIME'
            value: 'powershell'
          }
          {
            name: 'WEBSITE_LOAD_USER_PROFILE'
            value: '1'
          }
          {
            name: 'EnvironmentName'
            value: environment().name
          }
          {
            name: 'ResourceManagerUrl'
            // This workaround is needed because the environment().resourceManager value is missing the trailing slash for some Azure environments
            value: endsWith(environment().resourceManager, '/')
              ? environment().resourceManager
              : '${environment().resourceManager}/'
          }
          {
            name: 'StorageSuffix'
            value: environment().suffixes.storage
          }
          {
            name: 'SubscriptionId'
            value: subscription().subscriptionId
          }
          {
            name: 'TenantId'
            value: subscription().tenantId
          }
        ],
        enableApplicationInsights
          ? [
              {
                name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
                value: applicationInsights.properties.ConnectionString
              }
            ]
          : [],
        functionAppAppSettings
      )
      cors: {
        allowedOrigins: [
          '${environment().portal}'
          'https://functions-next.${cloudSuffix}'
          'https://functions-staging.${cloudSuffix}'
          'https://functions.${cloudSuffix}'
        ]
      }
      ftpsState: 'Disabled'
      netFrameworkVersion: 'v6.0'
      powerShellVersion: '7.4'
      publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
      use32BitWorkerProcess: false
    }
    virtualNetworkSubnetId: !empty(functionAppDelegatedSubnetResourceId) ? functionAppDelegatedSubnetResourceId : null
    vnetContentShareEnabled: false
    vnetRouteAllEnabled: !empty(functionAppDelegatedSubnetResourceId) ? true : false
  }
}

resource privateEndpoint_functionApp 'Microsoft.Network/privateEndpoints@2023-04-01' = if (privateEndpoint) {
  name: replace(
    replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'sites'), 'RESOURCE', functionApp.name),
    'VNETID',
    peVnetId
  )
  location: location
  properties: {
    customNetworkInterfaceName: replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'sites'), 'RESOURCE', functionApp.name),
      'VNETID',
      peVnetId
    )
    privateLinkServiceConnections: [
      {
        name: replace(
          replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'sites'), 'RESOURCE', functionApp.name),
          'VNETID',
          peVnetId
        )
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetResourceId
    }
  }
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Network/privateEndpoints'] ?? {})
}

resource privateDnsZoneGroup_functionApp 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-08-01' = if (privateEndpoint && !empty(azureFunctionAppPrivateDnsZoneResourceId)) {
  parent: privateEndpoint_functionApp
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'ipconfig1'
        properties: {
          #disable-next-line use-resource-id-functions
          privateDnsZoneId: azureFunctionAppPrivateDnsZoneResourceId
        }
      }
    ]
  }
}

module roleAssignments_resourceGroups '../../../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = [
  for i in range(0, length(resourceGroupRoleAssignments)): {
    name: 'set-role-assignment-${i}-${timeStamp}'
    scope: resourceGroup(resourceGroupRoleAssignments[i].scope)
    params: {
      principalId: functionApp.identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: resourceGroupRoleAssignments[i].roleDefinitionId
    }
  }
]

module roleAssignment_storageAccount '../roleAssignment-storageAccount.bicep' = {
  name: 'set-role-assignment-storage-${timeStamp}'
  params: {
    principalIds: [functionApp.identity.principalId]
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
    storageAccountResourceId: storageAccount.id
  }
}

output functionAppName string = functionApp.name

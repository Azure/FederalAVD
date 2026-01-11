param applicationInsightsName string
param azureBlobPrivateDnsZoneResourceId string
param azureFunctionAppPrivateDnsZoneResourceId string
param azureQueuePrivateDnsZoneResourceId string
param azureTablePrivateDnsZoneResourceId string
param deploymentSuffix string
param enableApplicationInsights bool
param encryptionKeyName string
param encryptionKeyVaultResourceId string
param functionAppDelegatedSubnetResourceId string
param functionAppName string
param functionAppAppSettings array
param functionAppUserAssignedIdentityResourceId string = ''
param hostPoolResourceId string
@allowed([
  'MicrosoftManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
param keyManagementStorageAccounts string
param location string
param logAnalyticsWorkspaceResourceId string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param privateEndpointSubnetResourceId string
param privateLinkScopeResourceId string
param storageAccountRoleDefinitionIds array = []
param serverFarmId string
param storageAccountName string
param tags object

var cloudSuffix = replace(replace(environment().resourceManager, 'https://management.', ''), '/', '')
// ensure that private endpoint name and nic name are not longer than 80
var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var peVnetId = length(privateEndpointVnetName) < 37 ? privateEndpointVnetName : uniqueString(privateEndpointVnetName)

var azureStoragePrivateDnsZoneResourceIds = [
  azureBlobPrivateDnsZoneResourceId
  azureQueuePrivateDnsZoneResourceId
  azureTablePrivateDnsZoneResourceId
]

var storageSubResources = [
  'blob'
  'queue'
  'table'
]

resource functionAppUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (!empty(functionAppUserAssignedIdentityResourceId)) {
  name: last(split(functionAppUserAssignedIdentityResourceId, '/'))
  scope: resourceGroup(
    split(functionAppUserAssignedIdentityResourceId, '/')[2],
    split(functionAppUserAssignedIdentityResourceId, '/')[4]
  )
}

// Create the Function App Storage Account with Microsoft Managed Keys first
resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: keyManagementStorageAccounts != 'MicrosoftManaged'
    ? {
        type: 'SystemAssigned'
      }
    : null
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: true
    dnsEndpointType: 'Standard'
    encryption: {
      requireInfrastructureEncryption: true
      services: {
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
  resource blobService 'blobServices' = {
    name: 'default'
  }
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
  for i in range(0, length(azureStoragePrivateDnsZoneResourceIds) - 1): if (privateEndpoint && !empty(azureStoragePrivateDnsZoneResourceIds[i])) {
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
  scope: storageAccount::blobService
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

module encryptionKey 'encryptionKey.bicep' = if (keyManagementStorageAccounts != 'MicrosoftManaged') {
  name: 'encryptionKey-storageAccount-${deploymentSuffix}'
  params: {
    encryptionKeyName: encryptionKeyName
    hostPoolResourceId: hostPoolResourceId
    deploymentSuffix: deploymentSuffix
    keyManagementStorageAccounts: keyManagementStorageAccounts
    keyVaultResourceId: encryptionKeyVaultResourceId
    storageAccountPrincipalId: storageAccount.identity.principalId
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = if (enableApplicationInsights) {
  name: applicationInsightsName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Insights/components'] ?? {})
  properties: {
    Application_Type: 'web'
    // Enable public ingestion when no Private Link Scope is configured
    // Disable when Private Link Scope exists to force traffic through private endpoint
    publicNetworkAccessForIngestion: empty(privateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
    publicNetworkAccessForQuery: empty(privateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
    WorkspaceResourceId: logAnalyticsWorkspaceResourceId
  }
  kind: 'web'
}

module updatePrivateLinkScope '../privateLinkScopes/get-PrivateLinkScope.bicep' = if (enableApplicationInsights && !empty(privateLinkScopeResourceId)) {
  name: 'PrivateLlinkScope-${deploymentSuffix}'
  scope: subscription()
  params: {
    privateLinkScopeResourceId: privateLinkScopeResourceId
    scopedResourceIds: [
      applicationInsights.id
    ]
    deploymentSuffix: deploymentSuffix
  }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Web/sites'] ?? {})
  kind: 'functionapp'
  identity: !empty(functionAppUserAssignedIdentityResourceId)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${functionAppUserAssignedIdentityResourceId}': {}
        }
      }
    : {
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
        empty(functionAppUserAssignedIdentityResourceId)
          ? []
          : [
              {
                name: 'AzureWebJobsStorage__clientId'
                value: functionAppUAI!.properties.clientId
              }
              {
                name: 'UserAssignedIdentityClientId'
                value: functionAppUAI!.properties.clientId
              }
            ],
        [
          {
            name: 'AzureWebJobsStorage__credential'
            value: 'managedidentity'
          }
          {
            name: 'AzureWebJobsStorage__blobServiceUri'
            value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}'
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
            name: 'ResourceManagerUri'
            // This workaround is needed because the environment().resourceManager value is missing the trailing slash for some Azure environments
            value: environment().resourceManager
          }
          {
            name: 'StorageSuffix'
            value: environment().suffixes.storage
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
                value: applicationInsights!.properties.ConnectionString
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
        supportCredentials: false
      }
      ftpsState: 'Disabled'
      functionAppScaleLimit: 200
      minimumElasticInstanceCount: 0
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

// Get principal ID from User-Assigned Identity if provided, otherwise use System-Assigned
// Get the principal ID of the identity being used (user-assigned if provided, otherwise system-assigned)
var functionAppPrincipalId = !empty(functionAppUserAssignedIdentityResourceId)
  ? functionAppUAI!.properties.principalId
  : functionApp.identity.principalId

// Storage account role assignments - always include Storage Blob Data Contributor and Storage Queue Data Contributor, optionally add others
var storageAccountRoleDefinitions = union(
  [
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor (always required)
    '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
  ],
  storageAccountRoleDefinitionIds
)

module roleAssignment_storageAccount '../../resources/storage/storage-account/rbac.bicep' = [
  for roleDefinitionId in storageAccountRoleDefinitions: {
    name: 'set-role-assignment-storage-${uniqueString(roleDefinitionId)}-${deploymentSuffix}'
    params: {
      principalIds: [functionAppPrincipalId]
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleDefinitionId
      storageAccountResourceId: storageAccount.id
    }
  }
]

// Update storage account with customer managed key encryption. Force this to end to allow time for RBAC to propagate.
module updateStorageAccount 'updateStorageAccountKey.bicep' = if (keyManagementStorageAccounts != 'MicrosoftManaged') {
  name: 'update-encryptionKey-storageAccount-${deploymentSuffix}'
  params: {
    storageAccountName: storageAccount.name
    storageAccountSku: storageAccount.sku
    encryptionKeyName: encryptionKey!.outputs.encryptionKeyName
    keyVaultResourceId: encryptionKeyVaultResourceId
    location: location
    storageAccountKind: storageAccount.kind
  }
  dependsOn: [
    functionApp
  ]
}

output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionAppPrincipalId
output applicationInsightsResourceId string = enableApplicationInsights ? applicationInsights.id : ''

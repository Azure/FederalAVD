@description('Optional. Name of the Application Insights resource to create when enableApplicationInsights is true.')
param applicationInsightsName string = ''

@description('Required. Resource ID of the private DNS zone for blob endpoints (typically privatelink.blob.core.windows.net).')
param azureBlobPrivateDnsZoneResourceId string

@description('Required. Resource ID of the private DNS zone for Function App private endpoints (typically privatelink.azurewebsites.net).')
param azureFunctionAppPrivateDnsZoneResourceId string

@description('Optional. Resource ID of the private DNS zone for queue endpoints (typically privatelink.queue.core.windows.net).')
param azureQueuePrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the private DNS zone for table endpoints (typically privatelink.table.core.windows.net).')
param azureTablePrivateDnsZoneResourceId string = ''

@description('Required. Unique suffix used for deterministic deployment naming and idempotency.')
param deploymentSuffix string

@description('Optional. Enables creation and wiring of Application Insights for the Function App.')
param enableApplicationInsights bool = false

@description('Optional. Enables queue endpoint configuration for AzureWebJobsStorage and queue private endpoint DNS integration.')
param enableQueueStorage bool = true

@description('Optional. Enables table endpoint configuration for AzureWebJobsStorage and table private endpoint DNS integration.')
param enableTableStorage bool = true

@description('Required when CMK is used. Name of the Key Vault key referenced by storage account encryption settings.')
param encryptionKeyName string

@description('Optional. Resource ID of the Key Vault containing the CMK used for storage account encryption.')
param encryptionKeyVaultResourceId string

@description('Optional. Resource ID of a delegated subnet for Function App regional VNet integration.')
param functionAppDelegatedSubnetResourceId string

@description('Required. Name of the Function App.')
param functionAppName string

@description('Optional. Additional app settings merged into the default Function App configuration.')
param functionAppAppSettings array

@description('Optional. Existing user-assigned identity resource ID for the Function App. When omitted, system-assigned identity is used.')
param functionAppUserAssignedIdentityResourceId string = ''

@description('Required. Parent host pool resource ID used for traceability tags.')
param hostPoolResourceId string
@allowed([
  'MicrosoftManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
@description('Required. Storage encryption key management mode for the Function App storage account.')

param keyManagementStorageAccounts string

@description('Required. Azure region for resources in this module.')
param location string

@description('Optional. Log Analytics workspace resource ID used for Application Insights workspace-based mode.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. Enables or disables deployment of private endpoints for storage and Function App.')
param privateEndpoint bool

@description('Required. Naming convention template for private endpoint resources (supports RESOURCE/SUBRESOURCE/VNETID placeholders).')
param privateEndpointNameConv string

@description('Required. Naming convention template for private endpoint NIC resources (supports RESOURCE/SUBRESOURCE/VNETID placeholders).')
param privateEndpointNICNameConv string


@description('Required when privateEndpoint is true. Subnet resource ID used by private endpoints.')
param privateEndpointSubnetResourceId string

@description('Optional. Azure Monitor Private Link Scope resource ID used to associate Application Insights over Private Link.')
param privateLinkScopeResourceId string = ''

@description('Optional. Additional role definition IDs assigned to the Function App identity on the storage account.')
param storageAccountRoleDefinitionIds array = []

@description('Required. App Service plan (server farm) resource ID for the Function App.')
param serverFarmId string

@description('Optional. Name for the storage encryption user-assigned identity to create when CMK is selected and functionAppUserAssignedIdentityResourceId is not provided. Computed by caller using naming convention. Required when keyManagementStorageAccounts != MicrosoftManaged and functionAppUserAssignedIdentityResourceId is empty.')
param storageEncryptionIdentityName string = ''

@description('Required. Name of the storage account used by the Function App runtime.')
param storageAccountName string

@description('Optional. Array of permitted IP addresses or CIDR blocks for the function app storage account firewall. When provided alongside a private endpoint, the firewall remains open to these IPs while still requiring PE for all other traffic.')
param permittedIPs array = []

@description('Required. Tag object with resource-type keys used to stamp deployed resources.')
param tags object

var cloudSuffix = replace(replace(environment().resourceManager, 'https://management.', ''), '/', '')
// ensure that private endpoint name and nic name are not longer than 80
var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var peVnetId = length(privateEndpointVnetName) < 37 ? privateEndpointVnetName : uniqueString(privateEndpointVnetName)

var storageIpRules = [for ip in permittedIPs: { value: ip, action: 'Allow' }]

var permittedIPRestrictions = [for (ip, i) in permittedIPs: {
  ipAddress: ip
  action: 'Allow'
  priority: 100 + i
  name: 'PermittedIP-${i}'
}]

var azureCloudRestriction = [
  {
    ipAddress: 'AzureCloud'
    action: 'Allow'
    tag: 'ServiceTag'
    priority: 200
    name: 'AzureCloud'
  }
  {
    ipAddress: 'Any'
    action: 'Deny'
    priority: 2147483647
    name: 'Deny all'
    description: 'Deny all access'
  }
]

var resolvedIpSecurityRestrictions = (privateEndpoint || !empty(permittedIPs))
  ? union(permittedIPRestrictions, azureCloudRestriction)
  : null

// Build arrays dynamically based on which storage types are enabled
var storageSubResources = union(
  ['blob'], // Always required
  enableQueueStorage ? ['queue'] : [],
  enableTableStorage ? ['table'] : []
)

var azureStoragePrivateDnsZoneResourceIds = union(
  [azureBlobPrivateDnsZoneResourceId], // Always required
  enableQueueStorage && !empty(azureQueuePrivateDnsZoneResourceId) ? [azureQueuePrivateDnsZoneResourceId] : [],
  enableTableStorage && !empty(azureTablePrivateDnsZoneResourceId) ? [azureTablePrivateDnsZoneResourceId] : []
)

resource functionAppUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (!empty(functionAppUserAssignedIdentityResourceId)) {
  name: last(split(functionAppUserAssignedIdentityResourceId, '/'))
  scope: resourceGroup(
    split(functionAppUserAssignedIdentityResourceId, '/')[2],
    split(functionAppUserAssignedIdentityResourceId, '/')[4]
  )
}

var useCmk = keyManagementStorageAccounts != 'MicrosoftManaged'
// Create a dedicated storage encryption UAI when CMK is selected but no existing UAI is supplied.
// When an existing functionAppUserAssignedIdentityResourceId is provided, reuse it for CMK instead.
var createStorageEncryptionUai = useCmk && empty(functionAppUserAssignedIdentityResourceId)

// Delegate all CMK resource creation (key, UAI, role assignment) to the unified module.
// This replaces the inline key/UAI/RA boilerplate that was previously duplicated here.
module cmk '../customerManagedKeys/customerManagedKeys.bicep' = if (createStorageEncryptionUai) {
  name: 'CMK-FunctionAppStorage-${deploymentSuffix}'
  params: {
    keyVaultResourceId: encryptionKeyVaultResourceId
    keyManagementType: keyManagementStorageAccounts == 'CustomerManagedHSM' ? 'CustomerManagedHSM' : 'CustomerManaged'
    location: location
    tags: tags
    parentResourceId: hostPoolResourceId
    deploymentSuffix: deploymentSuffix
    paasKeyNames: [encryptionKeyName]
    paasIdentityName: storageEncryptionIdentityName
  }
}

// Resolve Key Vault URI for the storage account encryption property.
resource encryptionKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (useCmk && !empty(encryptionKeyVaultResourceId)) {
  name: last(split(encryptionKeyVaultResourceId, '/'))
  scope: resourceGroup(
    split(encryptionKeyVaultResourceId, '/')[2],
    split(encryptionKeyVaultResourceId, '/')[4]
  )
}

// Resolved CMK identity — either the provided function app UAI or the newly created storage encryption UAI.
// The resource ID is computed from parameters (not module output) so it can be used as a userAssignedIdentities
// property key, which ARM requires to be calculable at deployment start.
var storageEncryptionUaiResourceId = createStorageEncryptionUai
  ? resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', storageEncryptionIdentityName)
  : ''

var cmkUaiResourceId = useCmk
  ? !empty(functionAppUserAssignedIdentityResourceId)
      ? functionAppUserAssignedIdentityResourceId
      : storageEncryptionUaiResourceId
  : ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.Storage/storageAccounts'] ?? {})
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: useCmk
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${cmkUaiResourceId}': {}
        }
      }
    : null
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowedCopyScope: privateEndpoint ? 'PrivateLink' : 'AAD'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    dnsEndpointType: 'Standard'
    encryption: {
      keySource: useCmk ? 'Microsoft.Keyvault' : 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: union(
        {
          blob: {
            keyType: 'Account'
            enabled: true
          }
        },
        enableQueueStorage
          ? {
              queue: {
                keyType: 'Account'
                enabled: true
              }
            }
          : {},
        enableTableStorage
          ? {
              table: {
                keyType: 'Account'
                enabled: true
              }
            }
          : {}
      )
      keyvaultproperties: useCmk
        ? {
            keyname: encryptionKeyName
            keyvaulturi: encryptionKeyVault!.properties.vaultUri
          }
        : null
      identity: useCmk
        ? {
            userAssignedIdentity: cmkUaiResourceId
          }
        : null
    }
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: storageIpRules
      defaultAction: (privateEndpoint || !empty(storageIpRules)) ? 'Deny' : 'Allow'
    }
    publicNetworkAccess: (privateEndpoint && empty(storageIpRules)) ? 'Disabled' : 'Enabled'
    sasPolicy: {
      expirationAction: 'Log'
      sasExpirationPeriod: '180.00:00:00'
    }
    supportsHttpsTrafficOnly: true
  }
  resource blobService 'blobServices' = {
    name: 'default'
  }
  dependsOn: [cmk]
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
  for i in range(0, length(azureStoragePrivateDnsZoneResourceIds)): if (privateEndpoint && !empty(azureStoragePrivateDnsZoneResourceIds[i])) {
    parent: privateEndpoints_storage[i]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: replace(last(split(azureStoragePrivateDnsZoneResourceIds[i], '/'))!, '.', '-')
          properties: {
            #disable-next-line use-resource-id-functions
            privateDnsZoneId: azureStoragePrivateDnsZoneResourceIds[i]
          }
        }
      ]
    }
  }
]

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

module updatePrivateLinkScope '../get-PrivateLinkScope.bicep' = if (enableApplicationInsights && !empty(privateLinkScopeResourceId)) {
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

resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
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
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
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
        ],
        enableQueueStorage
          ? [
              {
                name: 'AzureWebJobsStorage__queueServiceUri'
                value: 'https://${storageAccount.name}.queue.${environment().suffixes.storage}'
              }
            ]
          : [],
        enableTableStorage
          ? [
              {
                name: 'AzureWebJobsStorage__tableServiceUri'
                value: 'https://${storageAccount.name}.table.${environment().suffixes.storage}'
              }
            ]
          : [],
        [
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
      ipSecurityRestrictions: resolvedIpSecurityRestrictions
      ipSecurityRestrictionsDefaultAction: (privateEndpoint || !empty(permittedIPs)) ? 'Deny' : null
      scmIpSecurityRestrictions: (privateEndpoint || !empty(permittedIPs)) ? [
        {
          ipAddress: 'Any'
          action: 'Deny'
          priority: 2147483647
          name: 'Deny all'
          description: 'Deny all access'
        }
      ] : null
      scmIpSecurityRestrictionsDefaultAction: (privateEndpoint || !empty(permittedIPs)) ? 'Deny' : null
      scmIpSecurityRestrictionsUseMain: (privateEndpoint || !empty(permittedIPs)) ? true : null
      publicNetworkAccess: (privateEndpoint && empty(permittedIPs)) ? 'Disabled' : 'Enabled'
      use32BitWorkerProcess: false
    }
    outboundVnetRouting: empty(functionAppDelegatedSubnetResourceId)
      ? null
      : {
          allTraffic: true
          applicationTraffic: true
        }
    virtualNetworkSubnetId: !empty(functionAppDelegatedSubnetResourceId) ? functionAppDelegatedSubnetResourceId : null
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
        name: replace(last(split(azureFunctionAppPrivateDnsZoneResourceId, '/'))!, '.', '-')
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

module roleAssignment_storageAccount '../../storage/storageAccounts/roleAssignment.bicep' = {
  name: 'set-role-assignments-storage-${deploymentSuffix}'
  params: {
    storageAccountName: storageAccount.name
    assignments: [
      for roleDefinitionId in storageAccountRoleDefinitions: {
        principalId: functionAppPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: roleDefinitionId
      }
    ]
  }
}

@description('Name of the deployed Function App.')
output functionAppName string = functionApp.name

@description('Principal ID of the identity used by the Function App (UAI when provided, otherwise SAI).')
output functionAppPrincipalId string = functionAppPrincipalId

@description('Resource ID of Application Insights when enabled; otherwise empty string.')
output applicationInsightsResourceId string = enableApplicationInsights ? applicationInsights.id : ''

import { publicNetworkAccessMode, resolveNetworkAccess } from '../../orchestration/networking/functions.bicep'

@description('Optional. Name of the Application Insights resource to create when enableApplicationInsights is true.')
param applicationInsightsName string = ''

@description('Required input; may be empty when blob private DNS integration is not selected. Resource ID of the target-cloud blob private DNS zone. Zone groups are created only when privateEndpoint is true.')
param azureBlobPrivateDnsZoneResourceId string

@description('Required input; may be empty when Function App private DNS integration is not selected. Resource ID of the target-cloud Function App private DNS zone. Zone groups are created only when privateEndpoint is true.')
param azureFunctionAppPrivateDnsZoneResourceId string

@description('Optional. Resource ID of the private DNS zone for queue endpoints (typically privatelink.queue.core.windows.net).')
param azureQueuePrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the private DNS zone for table endpoints (typically privatelink.table.core.windows.net).')
param azureTablePrivateDnsZoneResourceId string = ''

@description('Optional. Enables creation and wiring of Application Insights for the Function App.')
param enableApplicationInsights bool = false

@description('Optional. Enables queue endpoint configuration for AzureWebJobsStorage and queue private endpoint DNS integration.')
param enableQueueStorage bool = true

@description('Optional. Enables table endpoint configuration for AzureWebJobsStorage and table private endpoint DNS integration.')
param enableTableStorage bool = true

@description('Required input; may be empty for PlatformManaged encryption. For CMK, the caller must provision this Key Vault key and storage encryption identity permissions before invoking the module.')
param encryptionKeyName string

@description('Required input; may be empty for PlatformManaged encryption. For CMK, resource ID of the existing Key Vault containing encryptionKeyName.')
param encryptionKeyVaultResourceId string

@description('Required input; may be empty to omit regional VNet integration. When provided, supplies the delegated subnet and enables outbound VNet routing. Private endpoints alone do not configure outbound connectivity.')
param functionAppDelegatedSubnetResourceId string

@description('Required. Name of the Function App.')
param functionAppName string

@description('Required. Additional app-setting name/value objects merged into the default runtime and managed-identity settings. Pass an empty array when no additional settings are needed.')
param functionAppAppSettings array

@description('Optional. PowerShell worker version for the Function App. Use a version supported by Azure Functions runtime v4 in the deployment region. Preview versions are permitted.')
param powerShellVersion string = '7.4'

@description('Optional. Existing user-assigned identity resource ID for the Function App. When omitted, system-assigned identity is used.')
param functionAppUserAssignedIdentityResourceId string = ''

@description('Required. Parent host pool resource ID used for traceability tags.')
param hostPoolResourceId string
@allowed([
  'PlatformManaged'
  'CustomerManaged'
  'CustomerManagedHSM'
])
@description('Required. Storage encryption key management mode for the Function App storage account.')

param keyManagementStorageAccounts string

@description('Required. Azure region for resources in this module.')
param location string

@description('Optional. Log Analytics workspace resource ID used for Application Insights workspace-based mode.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Required. Creates storage and Function App private endpoints when true. Public access is controlled separately by paasPublicNetworkAccess.')
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

@description('Required. Resource ID of the caller-created or existing App Service plan. This module does not create or change the plan; its operating system, region, and SKU must support the app configuration.')
param serverFarmId string

// Required for CMK. Name of the dedicated storage encryption identity already provisioned by the
// caller in this resource group, with Key Vault Crypto Service Encryption User on the key. It is
// separate from the Function App identity; this module does not create it.
@description('Required for CMK. Existing dedicated storage encryption identity name in this resource group, with Key Vault Crypto Service Encryption User on the key; not the app identity.')
param storageEncryptionIdentityName string = ''

@description('Required. Name of the storage account used by the Function App runtime.')
param storageAccountName string

// Function App restrictions include AzureCloud; storage retains AzureServices bypass.
// Explicit Disabled retains these rules without enabling the public endpoint.
@description('Optional. Allowed app/storage public IPs/CIDRs, retained in all access modes. AzureCloud/AzureServices exceptions also apply; reachability does not grant authorization.')
param permittedIPs array = []

@description('Optional. Shared app/storage public-access mode. Auto preserves legacy private-endpoint/IP inference. Monitoring access remains separately configured.')
param paasPublicNetworkAccess publicNetworkAccessMode = 'Auto'

@description('Required. Tag object with resource-type keys used to stamp deployed resources.')
param tags object

var cloudSuffix = replace(replace(environment().resourceManager, 'https://management.', ''), '/', '')
// ensure that private endpoint name and nic name are not longer than 80
var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var peVnetId = length(privateEndpointVnetName) < 37 ? privateEndpointVnetName : uniqueString(privateEndpointVnetName)

var effectivePermittedIPs = filter(permittedIPs, ip => !empty(trim(ip)))
var networkAccess = resolveNetworkAccess(paasPublicNetworkAccess, privateEndpoint, !empty(effectivePermittedIPs))
var restrictPublicAccess = networkAccess.defaultAction == 'Deny'
var storagePermittedIPs = [for ip in effectivePermittedIPs: endsWith(trim(ip), '/32')
  ? replace(trim(ip), '/32', '')
  : trim(ip)]
var functionAppPermittedIPs = [for ip in effectivePermittedIPs: contains(trim(ip), '/') ? trim(ip) : '${trim(ip)}/32']
var storageIpRules = [for ip in storagePermittedIPs: { value: ip, action: 'Allow' }]

var permittedIPRestrictions = [for (ip, i) in functionAppPermittedIPs: {
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

// An explicit deny-all rule would override Allow in unrestricted mode. Retain allow entries,
// but emit the catch-all deny only in restricted/disabled modes.
var resolvedIpSecurityRestrictions = (restrictPublicAccess || !empty(effectivePermittedIPs))
  ? union(permittedIPRestrictions, restrictPublicAccess ? azureCloudRestriction : [azureCloudRestriction[0]])
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

var useCmk = keyManagementStorageAccounts != 'PlatformManaged'
// Always use the dedicated storage encryption UAI created by the caller when CMK is selected.
// The function app UAI (functionAppUserAssignedIdentityResourceId) is for the function app identity
// (Graph API permissions, etc.) and must NOT be reused for CMK — it would never receive
// Key Vault Crypto Service Encryption User, causing KeyVaultAuthenticationFailure at deploy time.

// Resolve Key Vault URI for the storage account encryption property.
resource encryptionKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (useCmk && !empty(encryptionKeyVaultResourceId)) {
  name: last(split(encryptionKeyVaultResourceId, '/'))
  scope: resourceGroup(
    split(encryptionKeyVaultResourceId, '/')[2],
    split(encryptionKeyVaultResourceId, '/')[4]
  )
}

// Resolved CMK identity — always the dedicated storage encryption UAI when CMK is enabled.
// This is deliberately separate from functionAppUserAssignedIdentityResourceId so the function
// app UAI does not need Key Vault Crypto Service Encryption User (it has broader permissions).
// The resource ID is computed from parameters (not module output) so it can be used as a
// userAssignedIdentities property key, which ARM requires to be calculable at deployment start.
var storageEncryptionUaiResourceId = useCmk
  ? resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', storageEncryptionIdentityName)
  : ''

var cmkUaiResourceId = useCmk ? storageEncryptionUaiResourceId : ''

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
      defaultAction: networkAccess.defaultAction
    }
    publicNetworkAccess: networkAccess.publicNetworkAccess
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

module updatePrivateLinkScope '../privateLinkScope/get-PrivateLinkScope.bicep' = if (enableApplicationInsights && !empty(privateLinkScopeResourceId)) {
  scope: subscription()
  params: {
    privateLinkScopeResourceId: privateLinkScopeResourceId
    scopedResourceIds: [
      applicationInsights.id
    ]
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
    publicNetworkAccess: networkAccess.publicNetworkAccess
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
      netFrameworkVersion: 'v10.0'
      powerShellVersion: powerShellVersion
      ipSecurityRestrictions: resolvedIpSecurityRestrictions
      ipSecurityRestrictionsDefaultAction: (paasPublicNetworkAccess != 'Auto' || restrictPublicAccess) ? networkAccess.defaultAction : null
      scmIpSecurityRestrictions: restrictPublicAccess ? [
        {
          ipAddress: 'Any'
          action: 'Deny'
          priority: 2147483647
          name: 'Deny all'
          description: 'Deny all access'
        }
      ] : null
      scmIpSecurityRestrictionsDefaultAction: (paasPublicNetworkAccess != 'Auto' || restrictPublicAccess) ? networkAccess.defaultAction : null
      scmIpSecurityRestrictionsUseMain: (paasPublicNetworkAccess != 'Auto' || restrictPublicAccess) ? true : null
      publicNetworkAccess: networkAccess.publicNetworkAccess
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

resource functionAppDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: 'diag-${functionAppName}'
  scope: functionApp
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
    ]
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

// Storage account role assignments - always include roles required by AzureWebJobsStorage, optionally add others
var storageAccountRoleDefinitions = union(
  [
    'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
    '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
  ],
  storageAccountRoleDefinitionIds
)

module roleAssignment_storageAccount '../storage/storageAccounts/roleAssignment.bicep' = {
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
metadata name = 'Function App infrastructure'
// Deploys Windows PowerShell Function App infrastructure, runtime storage, optional monitoring and
// private endpoints, and storage RBAC in the deployment resource group. Requires a caller-provided
// plan; function code and storage CMK provisioning are separate.
metadata description = 'Deploys Windows PowerShell Function App infrastructure, runtime storage, storage RBAC, and optional monitoring/private endpoints. Plan, code, and storage CMK provisioning remain caller-owned.'

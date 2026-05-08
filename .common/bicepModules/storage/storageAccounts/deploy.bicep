import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

@allowed(['StorageV2', 'Storage', 'BlobStorage', 'BlockBlobStorage', 'FileStorage'])
param kind string = 'StorageV2'

@description('SKU/replication type.')
param skuName string = 'Standard_GRS'

@allowed(['Hot', 'Cool'])
param accessTier string = 'Hot'

param allowBlobPublicAccess bool = false
param allowCrossTenantReplication bool = false
param allowSharedKeyAccess bool = true
param defaultToOAuthAuthentication bool = false
param supportsHttpsTrafficOnly bool = true
param requireInfrastructureEncryption bool = true

@allowed(['TLS1_0', 'TLS1_1', 'TLS1_2'])
param minimumTlsVersion string = 'TLS1_2'

@allowed(['Standard', 'AzureDnsZone', ''])
param dnsEndpointType string = 'Standard'

param largeFileSharesState string = ''

@description('Optional. Whether this storage account is accessed via a private endpoint. When true and no permittedIPs or serviceEndpointSubnetIds are provided, public network access is disabled entirely.')
param privateEndpoint bool = false

@description('Optional. Array of permitted IP addresses or CIDR blocks. When provided, public access is enabled with a deny-by-default firewall allowing only these addresses.')
param permittedIPs array = []

@description('Optional. Subnet resource IDs for virtual network service endpoint rules.')
param serviceEndpointSubnetIds array = []

@description('Optional. Services allowed to bypass network rules. Set to "None" for stricter configurations that do not require trusted Azure service access (e.g., backup, monitoring).')
@allowed(['AzureServices', 'Logging', 'Metrics', 'None'])
param networkAclsBypass string = 'AzureServices'

@description('Optional. Scope restriction for copy operations.')
param allowedCopyScope string = ''

@description('Optional. SAS expiration period in format d.hh:mm:ss. Empty to disable.')
param sasExpirationPeriod string = ''

@description('Optional. Azure Files identity-based authentication settings object.')
param azureFilesIdentityBasedAuthentication object = {}

@description('Optional. Key Vault URI for customer-managed key encryption.')
param encryptionKeyVaultUri string = ''

@description('Optional. Key Vault key name for customer-managed encryption.')
param encryptionKeyName string = ''

@description('Optional. Resource ID of user-assigned identity with key vault access for CMK.')
param encryptionUserAssignedIdentityResourceId string = ''

param diagnosticSettings diagnosticSettingsType?

var ipRules = [for ip in permittedIPs: { value: ip, action: 'Allow' }]
var virtualNetworkRules = [for subnetId in serviceEndpointSubnetIds: { id: subnetId, action: 'Allow' }]
var hasFirewallRestrictions = privateEndpoint || !empty(permittedIPs) || !empty(serviceEndpointSubnetIds)
// Disable public access only when private endpoint is the sole access path (no trusted IPs or service endpoints need public access).
var resolvedPublicNetworkAccess = (privateEndpoint && empty(permittedIPs) && empty(serviceEndpointSubnetIds)) ? 'Disabled' : 'Enabled'

var supportsBlobService = kind == 'BlockBlobStorage' || kind == 'BlobStorage' || kind == 'StorageV2' || kind == 'Storage'
var supportsFileService = kind == 'FileStorage' || kind == 'StorageV2' || kind == 'Storage'

var useCmk = !empty(encryptionKeyVaultUri) && !empty(encryptionKeyName)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: kind
  sku: {
    name: skuName
  }
  identity: useCmk && !empty(encryptionUserAssignedIdentityResourceId)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${encryptionUserAssignedIdentityResourceId}': {}
        }
      }
    : null
  properties: {
    accessTier: kind == 'StorageV2' || kind == 'BlobStorage' ? accessTier : null
    allowBlobPublicAccess: allowBlobPublicAccess
    allowCrossTenantReplication: allowCrossTenantReplication
    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: defaultToOAuthAuthentication
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    minimumTlsVersion: minimumTlsVersion
    dnsEndpointType: !empty(dnsEndpointType) ? dnsEndpointType : null
    largeFileSharesState: !empty(largeFileSharesState) ? largeFileSharesState : null
    networkAcls: {
      bypass: hasFirewallRestrictions ? networkAclsBypass : 'AzureServices'
      defaultAction: hasFirewallRestrictions ? 'Deny' : 'Allow'
      virtualNetworkRules: virtualNetworkRules
      ipRules: ipRules
    }
    publicNetworkAccess: resolvedPublicNetworkAccess
    allowedCopyScope: !empty(allowedCopyScope) ? allowedCopyScope : null
    sasPolicy: !empty(sasExpirationPeriod)
      ? {
          expirationAction: 'Log'
          sasExpirationPeriod: sasExpirationPeriod
        }
      : null
    azureFilesIdentityBasedAuthentication: !empty(azureFilesIdentityBasedAuthentication)
      ? azureFilesIdentityBasedAuthentication
      : null
    encryption: {
      keySource: useCmk ? 'Microsoft.Keyvault' : 'Microsoft.Storage'
      services: {
        blob: supportsBlobService
          ? {
              enabled: true
            }
          : null
        file: supportsFileService
          ? {
              enabled: true
            }
          : null
        table: {
          enabled: true
        }
        queue: {
          enabled: true
        }
      }
      requireInfrastructureEncryption: kind != 'Storage' ? requireInfrastructureEncryption : null
      keyvaultproperties: useCmk
        ? {
            keyname: encryptionKeyName
            keyvaulturi: encryptionKeyVaultUri
          }
        : null
      identity: useCmk
        ? {
            userAssignedIdentity: encryptionUserAssignedIdentityResourceId
          }
        : null
    }
  }
}

var diagTargetNames = filter(
  [
    !empty(diagnosticSettings.?workspaceId ?? '') ? last(split(diagnosticSettings.?workspaceId!, '/')) : ''
    !empty(diagnosticSettings.?storageAccountId ?? '') ? last(split(diagnosticSettings.?storageAccountId!, '/')) : ''
    !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? '')
      ? (!empty(diagnosticSettings.?eventHubName ?? '')
          ? diagnosticSettings!.eventHubName!
          : split(diagnosticSettings.?eventHubAuthorizationRuleId!, '/')[8])
      : ''
  ],
  t => !empty(t)
)

var diagnosticSettingName = !empty(diagnosticSettings.?name ?? '')
  ? diagnosticSettings!.name!
  : length(diagTargetNames) > 1
      ? 'diag-${uniqueString(join(diagTargetNames, '-'))}'
      : length(diagTargetNames) == 1 ? 'diag-${diagTargetNames[0]}' : 'diagnostics'

resource diagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettings != null && (!empty(diagnosticSettings.?workspaceId ?? '') || !empty(diagnosticSettings.?storageAccountId ?? '') || !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? ''))) {
  scope: storageAccount
  name: diagnosticSettingName
  properties: {
    workspaceId: diagnosticSettings.?workspaceId
    storageAccountId: diagnosticSettings.?storageAccountId
    eventHubAuthorizationRuleId: diagnosticSettings.?eventHubAuthorizationRuleId
    eventHubName: diagnosticSettings.?eventHubName
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

output resourceId string = storageAccount.id
output name string = storageAccount.name

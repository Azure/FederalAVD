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

@description('Optional. Public network access setting for this storage account. Caller is responsible for resolving the correct value based on private endpoint topology, permitted IPs, and service endpoints.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Enabled'

@description('Network ACLs for the storage account. Caller is responsible for setting bypass, defaultAction, ipRules, and virtualNetworkRules appropriate to the deployment topology.')
param networkAcls object = {
  bypass: 'AzureServices'
  defaultAction: 'Deny'
  ipRules: []
  virtualNetworkRules: []
}

@description('Optional. Scope restriction for copy operations.')
param allowedCopyScope string = ''

@description('Optional. SAS expiration period in format d.hh:mm:ss. Empty to disable.')
param sasExpirationPeriod string = ''

@description('Optional. Azure Files identity-based authentication settings object.')
param azureFilesIdentityBasedAuthentication object = {}

@description('Optional. Customer-managed key URI for storage encryption.')
param cmkKeyUri string = ''

@description('Optional. User-assigned identity resource ID used for CMK access.')
param cmkUserAssignedIdentityResourceId string = ''

param diagnosticSettings diagnosticSettingsType?

var supportsBlobService = kind == 'BlockBlobStorage' || kind == 'BlobStorage' || kind == 'StorageV2' || kind == 'Storage'
var supportsFileService = kind == 'FileStorage' || kind == 'StorageV2' || kind == 'Storage'

var cmkConfigurationValidated = (empty(cmkKeyUri) || contains(cmkKeyUri, '/keys/')) && (empty(cmkKeyUri) == empty(cmkUserAssignedIdentityResourceId))
  ? true
  : bool('Invalid CMK configuration. Set both cmkKeyUri and cmkUserAssignedIdentityResourceId together (or neither), and ensure cmkKeyUri includes /keys/.')

var cmkKeyVaultUri = !empty(cmkKeyUri) ? '${split(cmkKeyUri, '/keys/')[0]}/' : ''
var cmkKeyPathSegments = split(!empty(cmkKeyUri) ? split(cmkKeyUri, '/keys/')[1] : '', '/')
var cmkKeyName = !empty(cmkKeyUri) ? cmkKeyPathSegments[0] : ''
var cmkKeyVersion = !empty(cmkKeyUri) && length(cmkKeyPathSegments) > 1 ? cmkKeyPathSegments[1] : ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: kind
  sku: {
    name: skuName
  }
  identity: !empty(cmkKeyUri)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${cmkUserAssignedIdentityResourceId}': {}
        }
      }
    : null
  properties: {
    accessTier: kind == 'StorageV2' || kind == 'BlobStorage' ? accessTier : null
    allowBlobPublicAccess: allowBlobPublicAccess
    allowCrossTenantReplication: allowCrossTenantReplication
    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: defaultToOAuthAuthentication
    supportsHttpsTrafficOnly: cmkConfigurationValidated ? supportsHttpsTrafficOnly : supportsHttpsTrafficOnly
    minimumTlsVersion: minimumTlsVersion
    dnsEndpointType: !empty(dnsEndpointType) ? dnsEndpointType : null
    largeFileSharesState: !empty(largeFileSharesState) ? largeFileSharesState : null
    networkAcls: networkAcls
    publicNetworkAccess: publicNetworkAccess
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
      keySource: !empty(cmkKeyUri) ? 'Microsoft.Keyvault' : 'Microsoft.Storage'
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
      keyvaultproperties: !empty(cmkKeyUri)
        ? {
            keyname: cmkKeyName
            keyvaulturi: cmkKeyVaultUri
            keyversion: !empty(cmkKeyVersion) ? cmkKeyVersion : null
          }
        : null
      identity: !empty(cmkKeyUri)
        ? {
            userAssignedIdentity: cmkUserAssignedIdentityResourceId
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

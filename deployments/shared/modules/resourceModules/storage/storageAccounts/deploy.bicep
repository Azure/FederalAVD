metadata name = 'Storage account'
metadata description = 'Deploys a storage account with caller-controlled network access, authentication, encryption and optional diagnostics.'

// CMK requires an existing authorized user-assigned identity and key.
// Services and private endpoints are managed separately.

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@description('Required. Name of the storage account to deploy.')
param name string
@description('Optional. Azure region for the storage account; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the storage account.')
param tags object = {}

@allowed(['StorageV2', 'Storage', 'BlobStorage', 'BlockBlobStorage', 'FileStorage'])
@description('Optional. Storage account kind; determines which data services and settings are supported.')
param kind string = 'StorageV2'

@description('SKU/replication type.')
param skuName string = 'Standard_GRS'

@allowed(['Hot', 'Cool'])
@description('Optional. Default Blob access tier; applied only to StorageV2 and BlobStorage accounts.')
param accessTier string = 'Hot'

@description('Optional. Permit containers to enable anonymous Blob access; individual container access is configured separately.')
param allowBlobPublicAccess bool = false
@description('Optional. Permit object replication across Microsoft Entra tenants.')
param allowCrossTenantReplication bool = false
@description('Optional. Permit storage requests authenticated with account keys.')
param allowSharedKeyAccess bool = true
@description('Optional. Make Microsoft Entra OAuth the default authentication method in the Azure portal.')
param defaultToOAuthAuthentication bool = false
@description('Optional. Require HTTPS for storage service requests.')
param supportsHttpsTrafficOnly bool = true
@description('Optional. Enable infrastructure encryption for account kinds other than legacy Storage.')
param requireInfrastructureEncryption bool = true

@allowed(['TLS1_0', 'TLS1_1', 'TLS1_2'])
@description('Optional. Minimum TLS version accepted by the storage account.')
param minimumTlsVersion string = 'TLS1_2'

@allowed(['Standard', 'AzureDnsZone', ''])
@description('Optional. Storage endpoint DNS format; empty omits the property.')
param dnsEndpointType string = 'Standard'

@description('Optional. Large file share capability state; empty leaves the property unspecified.')
param largeFileSharesState string = ''

// Resolve this value from the private endpoint topology, permitted IPs and service endpoints.
@description('Optional. Public network access setting for this storage account.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Enabled'

// The caller sets bypass, defaultAction, ipRules and virtualNetworkRules to match the deployment topology.
@description('Optional. Storage network ACL object with bypass, defaultAction, ipRules and virtualNetworkRules.')
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

// Referenced diagnostic destination resources must already exist.
@description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
param diagnosticSettings diagnosticSettingsType?

var supportsBlobService = kind == 'BlockBlobStorage' || kind == 'BlobStorage' || kind == 'StorageV2' || kind == 'Storage'
var supportsFileService = kind == 'FileStorage' || kind == 'StorageV2' || kind == 'Storage'

var cmkConfigurationValidated = (empty(cmkKeyUri) || contains(cmkKeyUri, '/keys/')) && (empty(cmkKeyUri) == empty(cmkUserAssignedIdentityResourceId))
  ? true
  : fail('Invalid CMK configuration. Set both cmkKeyUri and cmkUserAssignedIdentityResourceId together (or neither), and ensure cmkKeyUri includes /keys/.')

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

@description('Resource ID of the storage account.')
output resourceId string = storageAccount.id
@description('Azure resource name of the storage account.')
output name string = storageAccount.name

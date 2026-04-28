import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'
import { networkAclsType } from '../../types/storageTypes.bicep'

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

param networkAcls networkAclsType = {
  bypass: 'AzureServices'
  defaultAction: 'Deny'
  ipRules: []
  virtualNetworkRules: []
}

param publicNetworkAccess string = ''

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
    networkAcls: networkAcls
    publicNetworkAccess: !empty(publicNetworkAccess) ? publicNetworkAccess : null
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
    encryption: useCmk
      ? {
          keySource: 'Microsoft.Keyvault'
          requireInfrastructureEncryption: requireInfrastructureEncryption
          keyvaultproperties: {
            keyvaulturi: encryptionKeyVaultUri
            keyname: encryptionKeyName
          }
          identity: !empty(encryptionUserAssignedIdentityResourceId)
            ? {
                userAssignedIdentity: encryptionUserAssignedIdentityResourceId
              }
            : null
          services: {
            blob: { enabled: true, keyType: 'Account' }
            file: { enabled: true, keyType: 'Account' }
            queue: { enabled: true, keyType: 'Account' }
            table: { enabled: true, keyType: 'Account' }
          }
        }
      : {
          keySource: 'Microsoft.Storage'
          requireInfrastructureEncryption: requireInfrastructureEncryption
          services: {
            blob: { enabled: true, keyType: 'Account' }
            file: { enabled: true, keyType: 'Account' }
            queue: { enabled: true, keyType: 'Account' }
            table: { enabled: true, keyType: 'Account' }
          }
        }
  }
}

var diagTargetNames = filter([
  !empty(diagnosticSettings.?workspaceId ?? '') ? last(split(diagnosticSettings.?workspaceId!, '/')) : ''
  !empty(diagnosticSettings.?storageAccountId ?? '') ? last(split(diagnosticSettings.?storageAccountId!, '/')) : ''
  !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? '')
    ? (!empty(diagnosticSettings.?eventHubName ?? '') ? diagnosticSettings!.eventHubName! : split(diagnosticSettings.?eventHubAuthorizationRuleId!, '/')[8])
    : ''
], t => !empty(t))

var diagnosticSettingName = !empty(diagnosticSettings.?name ?? '')
  ? diagnosticSettings!.name!
  : length(diagTargetNames) > 1
      ? 'diag-${uniqueString(join(diagTargetNames, '-'))}'
      : length(diagTargetNames) == 1
          ? 'diag-${diagTargetNames[0]}'
          : 'diagnostics'

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
output primaryBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob

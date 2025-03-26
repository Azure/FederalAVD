@maxLength(24)
@description('Required. Name of the Storage Account.')
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. Enables system assigned managed identity on the resource.')
param systemAssignedIdentity bool = false

@description('Optional. The ID(s) to assign to the resource.')
param userAssignedIdentities object = {}

@allowed([
  'Storage'
  'StorageV2'
  'BlobStorage'
  'FileStorage'
  'BlockBlobStorage'
])
@description('Optional. Type of Storage Account to create.')
param kind string = 'StorageV2'

@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
@description('Optional. Storage Account Sku Name.')
param skuName string = 'Standard_GRS'

@allowed([
  'Premium'
  'Hot'
  'Cool'
])
@description('Conditional. Required if the Storage Account kind is set to BlobStorage. The access tier is used for billing. The "Premium" access tier is the default value for premium block blobs storage account type and it cannot be changed for the premium block blobs storage account type.')
param accessTier string = 'Hot'

@allowed([
  'Disabled'
  'Enabled'
])
@description('Optional. Allow large file shares if sets to \'Enabled\'. It cannot be disabled once it is enabled. Only supported on locally redundant and zone redundant file shares. It cannot be set on FileStorage storage accounts (storage accounts for premium file shares).')
param largeFileSharesState string = 'Disabled'

@description('Optional. Provides the identity based authentication settings for Azure Files.')
param azureFilesIdentityBasedAuthentication object = {}

@description('Optional. A boolean flag which indicates whether the default authentication is OAuth or not.')
param defaultToOAuthAuthentication bool = false

@description('Optional. Indicates whether the storage account permits requests to be authorized with the account access key via Shared Key. If false, then all requests, including shared access signatures, must be authorized with Azure Active Directory (Azure AD). The default value is null, which is equivalent to true.')
param allowSharedKeyAccess bool = true

@description('Optional. Configuration details for private endpoints. For security reasons, it is recommended to use private endpoints whenever possible.')
param privateEndpoints array = []


@description('Optional. The Storage Account ManagementPolicies Rules.')
param managementPolicyRules array = []

@description('Optional. Networks ACLs, this value contains IPs to whitelist and/or Subnet information. For security reasons, it is recommended to set the DefaultAction Deny.')
param networkAcls object = {}

@description('Optional. A Boolean indicating whether or not the service applies a secondary layer of encryption with platform managed keys for data at rest. For security reasons, it is recommended to set it to true.')
param requireInfrastructureEncryption bool = true

@description('Optional. Allow or disallow cross AAD tenant object replication.')
param allowCrossTenantReplication bool = true

@description('Optional. Sets the custom domain name assigned to the storage account. Name is the CNAME source.')
param customDomainName string = ''

@description('Optional. Indicates whether indirect CName validation is enabled. This should only be set on updates.')
param customDomainUseSubDomainName bool = false

@description('Optional. Allows you to specify the type of endpoint. Set this to AzureDNSZone to create a large number of accounts in a single subscription, which creates accounts in an Azure DNS Zone and the endpoint URL will have an alphanumeric DNS Zone identifier.')
@allowed([
  ''
  'AzureDnsZone'
  'Standard'
])
param dnsEndpointType string = ''

@description('Optional. Blob service and containers to deploy.')
param blobServices object = {}

@description('Optional. File service and shares to deploy.')
param fileServices object = {}

@description('Optional. Queue service and queues to create.')
param queueServices object = {}

@description('Optional. Table service and tables to create.')
param tableServices object = {}

@description('Optional. Indicates whether public access is enabled for all blobs or containers in the storage account. For security reasons, it is recommended to set it to false.')
param allowBlobPublicAccess bool = false

@allowed([
  'TLS1_0'
  'TLS1_1'
  'TLS1_2'
])
@description('Optional. Set the minimum TLS version on request to storage.')
param minimumTlsVersion string = 'TLS1_2'

@description('Conditional. If true, enables Hierarchical Namespace for the storage account. Required if enableSftp or enableNfsV3 is set to true.')
param enableHierarchicalNamespace bool = false

@description('Optional. If true, enables Secure File Transfer Protocol for the storage account. Requires enableHierarchicalNamespace to be true.')
param enableSftp bool = false

@description('Optional. Local users to deploy for SFTP authentication.')
param localUsers array = []

@description('Optional. Enables local users feature, if set to true.')
param isLocalUserEnabled bool = false

@description('Optional. If true, enables NFS 3.0 support for the storage account. Requires enableHierarchicalNamespace to be true.')
param enableNfsV3 bool = false

@description('Optional. Resource ID of the diagnostic log analytics workspace.')
param diagnosticWorkspaceId string = ''

@description('Optional. Tags of the resource.')
param tags object = {}

@description('Optional. Restrict copy to and from Storage Accounts within an AAD tenant or with Private Links to the same VNet.')
@allowed([
  ''
  'AAD'
  'PrivateLink'
])
param allowedCopyScope string = ''

@description('Optional. Whether or not public network access is allowed for this resource. For security reasons it should be disabled. If not specified, it will be disabled by default if private endpoints are set and networkAcls are not set.')
@allowed([
  ''
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = ''

@description('Optional. Allows HTTPS traffic only to storage service if sets to true.')
param supportsHttpsTrafficOnly bool = true

@description('Optional. The name of metrics that will be streamed.')
@allowed([
  'Transaction'
])
param diagnosticMetricsToEnable array = [
  'Transaction'
]

@description('Conditional. The resource ID of a key vault to reference a customer managed key for encryption from. Required if \'cMKKeyName\' is not empty.')
param cMKKeyVaultResourceId string = ''

@description('Optional. The name of the customer managed key to use for encryption. Cannot be deployed together with the parameter \'systemAssignedIdentity\' enabled.')
param cMKKeyName string = ''

@description('Conditional. User assigned identity to use when fetching the customer managed key. Required if \'cMKKeyName\' is not empty.')
param cMKUserAssignedIdentityResourceId string = ''

@description('Optional. The version of the customer managed key to reference for encryption. If not provided, latest is used.')
param cMKKeyVersion string = ''

@description('Optional. The name of the diagnostic setting, if deployed. If left empty, it defaults to "<resourceName>-diagnosticSettings".')
param diagnosticSettingsName string = ''

@description('Optional. The SAS expiration period. DD.HH:MM:SS.')
param sasExpirationPeriod string = ''

var diagnosticsMetrics = [for metric in diagnosticMetricsToEnable: {
  category: metric
  timeGrain: null
  enabled: true
}]

var supportsBlobService = kind == 'BlockBlobStorage' || kind == 'BlobStorage' || kind == 'StorageV2' || kind == 'Storage'
var supportsFileService = kind == 'FileStorage' || kind == 'StorageV2' || kind == 'Storage'

var identityType = systemAssignedIdentity ? (!empty(userAssignedIdentities) ? 'SystemAssigned,UserAssigned' : 'SystemAssigned') : (!empty(userAssignedIdentities) ? 'UserAssigned' : 'None')
var identity = identityType != 'None' ? {
  type: identityType
  userAssignedIdentities: !empty(userAssignedIdentities) ? userAssignedIdentities : null
} : null

resource keyVault 'Microsoft.KeyVault/vaults@2021-06-01-preview' existing = if (!empty(cMKKeyVaultResourceId)) {
  name: last(split(cMKKeyVaultResourceId, '/'))!
  scope: resourceGroup(split(cMKKeyVaultResourceId, '/')[2], split(cMKKeyVaultResourceId, '/')[4])
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: name
  location: location
  kind: kind
  sku: {
    name: skuName
  }
  identity: identity
  tags: tags
  properties: {
    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: defaultToOAuthAuthentication
    allowCrossTenantReplication: allowCrossTenantReplication
    allowedCopyScope: !empty(allowedCopyScope) ? allowedCopyScope : null
    customDomain: {
      name: customDomainName
      useSubDomainName: customDomainUseSubDomainName
    }
    dnsEndpointType: !empty(dnsEndpointType) ? dnsEndpointType : null
    isLocalUserEnabled: isLocalUserEnabled
    encryption: {
      keySource: !empty(cMKKeyName) ? 'Microsoft.Keyvault' : 'Microsoft.Storage'
      services: {
        blob: supportsBlobService ? {
          enabled: true
        } : null
        file: supportsFileService ? {
          enabled: true
        } : null
        table: {
          enabled: true
        }
        queue: {
          enabled: true
        }
      }
      requireInfrastructureEncryption: kind != 'Storage' ? requireInfrastructureEncryption : null
      keyvaultproperties: !empty(cMKKeyName) ? {
        keyname: cMKKeyName
        keyvaulturi: keyVault.properties.vaultUri
        keyversion: !empty(cMKKeyVersion) ? cMKKeyVersion : null
      } : null
      identity: !empty(cMKKeyName) ? {
        userAssignedIdentity: cMKUserAssignedIdentityResourceId
      } : null
    }
    accessTier: kind != 'Storage' ? accessTier : null
    sasPolicy: !empty(sasExpirationPeriod) ? {
      expirationAction: 'Log'
      sasExpirationPeriod: sasExpirationPeriod
    } : null
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    isHnsEnabled: enableHierarchicalNamespace ? enableHierarchicalNamespace : null
    isSftpEnabled: enableSftp
    isNfsV3Enabled: enableNfsV3 ? enableNfsV3 : any('')
    largeFileSharesState: (skuName == 'Standard_LRS') || (skuName == 'Standard_ZRS') ? largeFileSharesState : null
    minimumTlsVersion: minimumTlsVersion
    networkAcls: !empty(networkAcls) ? {
      bypass: networkAcls.?bypass ?? null
      defaultAction: networkAcls.?defaultAction ?? null
      virtualNetworkRules: networkAcls.?virtualNetworkRules ?? []
      ipRules: networkAcls.?ipRules ?? []
    } : {
      defaultAction: 'Deny'
      bypass: 'None'
    }
    allowBlobPublicAccess: allowBlobPublicAccess
    publicNetworkAccess: !empty(publicNetworkAccess) ? any(publicNetworkAccess) : (!empty(privateEndpoints) && empty(networkAcls) ? 'Disabled' : null)
    azureFilesIdentityBasedAuthentication: !empty(azureFilesIdentityBasedAuthentication) ? azureFilesIdentityBasedAuthentication : null
  }
}

resource storageAccount_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(diagnosticWorkspaceId)) {
  name: !empty(diagnosticSettingsName) ? diagnosticSettingsName : '${name}-diagnosticSettings'
  properties: {    
    workspaceId: !empty(diagnosticWorkspaceId) ? diagnosticWorkspaceId : null
    metrics: diagnosticsMetrics
  }
  scope: storageAccount
}

module storageAccount_privateEndpoints '../../network/private-endpoint/main.bicep' = [for (privateEndpoint, index) in privateEndpoints: {
  #disable-next-line BCP335
  name: 'StorageAccount-PrivateEndpoint-${index}-${uniqueString(deployment().name, location)}'
  params: {
    groupIds: [
      privateEndpoint.service
    ]
    name: privateEndpoint.?name ?? 'pe-${last(split(storageAccount.id, '/'))}-${privateEndpoint.service}-${index}'
    serviceResourceId: storageAccount.id
    subnetResourceId: privateEndpoint.subnetResourceId
    location: privateEndpoint.?location ?? reference(split(privateEndpoint.subnetResourceId, '/subnets/')[0], '2020-06-01', 'Full').location
    privateDnsZoneGroup: privateEndpoint.?privateDnsZoneGroup ?? {}
    tags: privateEndpoint.?tags ?? {}
    manualPrivateLinkServiceConnections: privateEndpoint.?manualPrivateLinkServiceConnections ?? []
    customDnsConfigs: privateEndpoint.?customDnsConfigs ?? []
    ipConfigurations: privateEndpoint.?ipConfigurations ?? []
    applicationSecurityGroups: privateEndpoint.?applicationSecurityGroups ?? []
    customNetworkInterfaceName: privateEndpoint.?customNetworkInterfaceName ?? ''
  }
}]

// Lifecycle Policy
module storageAccount_managementPolicies 'management-policy/main.bicep' = if (!empty(managementPolicyRules)) {
  name: 'Storage-ManagementPolicies-${uniqueString(deployment().name, location)}'
  params: {
    storageAccountName: storageAccount.name
    rules: managementPolicyRules
  }
  dependsOn: [
    storageAccount_blobServices // To ensure the lastAccessTimeTrackingPolicy is set first (if used in rule)
  ]
}

// SFTP user settings
module storageAccount_localUsers 'local-user/main.bicep' = [for (localUser, index) in localUsers: {
  name: 'Storage-LocalUsers-${index}-${uniqueString(deployment().name, location)}'
  params: {
    storageAccountName: storageAccount.name
    name: localUser.name
    hasSshKey: localUser.hasSshKey
    hasSshPassword: localUser.hasSshPassword
    permissionScopes: localUser.permissionScopes
    hasSharedKey: localUser.?hasSharedKey ?? false
    homeDirectory: localUser.?homeDirectory ?? ''
    sshAuthorizedKeys: localUser.?sshAuthorizedKeys ?? []
  }
}]

// Containers
module storageAccount_blobServices 'blob-service/main.bicep' = if (!empty(blobServices)) {
  name: 'Storage-BlobServices-${uniqueString(deployment().name, location)}'
  params: {
    storageAccountName: storageAccount.name
    containers: blobServices.?containers ?? []
    automaticSnapshotPolicyEnabled: blobServices.?automaticSnapshotPolicyEnabled ?? false
    changeFeedEnabled: blobServices.?changeFeedEnabled ?? false
    changeFeedRetentionInDays: blobServices.?changeFeedRetentionInDays ?? 7
    containerDeleteRetentionPolicyEnabled: blobServices.?containerDeleteRetentionPolicyEnabled ?? false
    containerDeleteRetentionPolicyDays: blobServices.?containerDeleteRetentionPolicyDays ?? 7
    containerDeleteRetentionPolicyAllowPermanentDelete: blobServices.?containerDeleteRetentionPolicyAllowPermanentDelete ?? false
    corsRules: blobServices.?corsRules ?? []
    defaultServiceVersion: blobServices.?defaultServiceVersion ?? ''
    deleteRetentionPolicyAllowPermanentDelete: blobServices.?deleteRetentionPolicyAllowPermanentDelete ?? false
    deleteRetentionPolicyEnabled: blobServices.?deleteRetentionPolicyEnabled ?? false
    deleteRetentionPolicyDays: blobServices.?deleteRetentionPolicyDays ?? 7
    isVersioningEnabled: blobServices.?isVersioningEnabled ?? false
    lastAccessTimeTrackingPolicyEnabled: blobServices.?lastAccessTimeTrackingPolicyEnabled ?? false
    restorePolicyEnabled: blobServices.?restorePolicyEnabled ?? false
    restorePolicyDays: blobServices.?restorePolicyDays ?? 6
    diagnosticStorageAccountId: blobServices.?diagnosticStorageAccountId ?? ''
    diagnosticEventHubAuthorizationRuleId: blobServices.?diagnosticEventHubAuthorizationRuleId ?? ''
    diagnosticEventHubName: blobServices.?diagnosticEventHubName ?? ''
    diagnosticLogCategoriesToEnable: blobServices.?diagnosticLogCategoriesToEnable ?? []
    diagnosticMetricsToEnable: blobServices.?diagnosticMetricsToEnable ?? []
    diagnosticWorkspaceId: blobServices.?diagnosticWorkspaceId ?? ''
  }
}

// File Shares
module storageAccount_fileServices 'file-service/main.bicep' = if (!empty(fileServices)) {
  name: 'Storage-FileServices-${uniqueString(deployment().name, location)}'
  params: {
    storageAccountName: storageAccount.name
    diagnosticStorageAccountId: fileServices.?diagnosticStorageAccountId ?? ''
    diagnosticEventHubAuthorizationRuleId: fileServices.?diagnosticEventHubAuthorizationRuleId ?? ''
    diagnosticEventHubName: fileServices.?diagnosticEventHubName ?? ''
    diagnosticLogCategoriesToEnable: fileServices.?diagnosticLogCategoriesToEnable ?? []
    diagnosticMetricsToEnable: fileServices.?diagnosticMetricsToEnable ?? []
    protocolSettings: fileServices.?protocolSettings ?? {}
    shareDeleteRetentionPolicy: fileServices.?shareDeleteRetentionPolicy ?? {
      enabled: true
      days: 7
    }
    shares: fileServices.?shares ?? []
    diagnosticWorkspaceId: fileServices.?diagnosticWorkspaceId ?? ''
  }
}

// Queue
module storageAccount_queueServices 'queue-service/main.bicep' = if (!empty(queueServices)) {
  name: 'Storage-QueueServices-${uniqueString(deployment().name, location)}'
  params: {
    storageAccountName: storageAccount.name
    diagnosticStorageAccountId: queueServices.?diagnosticStorageAccountId ?? ''
    diagnosticEventHubAuthorizationRuleId: queueServices.?diagnosticEventHubAuthorizationRuleId ?? ''
    diagnosticEventHubName: queueServices.?diagnosticEventHubName ?? ''
    diagnosticLogCategoriesToEnable: queueServices.?diagnosticLogCategoriesToEnable ?? []
    diagnosticMetricsToEnable: queueServices.?diagnosticMetricsToEnable ?? []
    queues: queueServices.?queues ?? []
    diagnosticWorkspaceId: queueServices.?diagnosticWorkspaceId ?? ''
  }
}

// Table
module storageAccount_tableServices 'table-service/main.bicep' = if (!empty(tableServices)) {
  name: 'Storage-TableServices-${uniqueString(deployment().name, location)}'
  params: {
    storageAccountName: storageAccount.name
    diagnosticStorageAccountId: tableServices.?diagnosticStorageAccountId ?? ''
    diagnosticEventHubAuthorizationRuleId: tableServices.?diagnosticEventHubAuthorizationRuleId ?? ''
    diagnosticEventHubName: tableServices.?diagnosticEventHubName ?? ''
    diagnosticLogCategoriesToEnable: tableServices.?diagnosticLogCategoriesToEnable ?? []
    diagnosticMetricsToEnable: tableServices.?diagnosticMetricsToEnable ?? []
    tables: tableServices.?tables ?? []
    diagnosticWorkspaceId: tableServices.?diagnosticWorkspaceId ?? ''
  }
}

@description('The resource ID of the deployed storage account.')
output resourceId string = storageAccount.id

@description('The name of the deployed storage account.')
output name string = storageAccount.name

@description('The resource group of the deployed storage account.')
output resourceGroupName string = resourceGroup().name

@description('The primary blob endpoint reference if blob services are deployed.')
output primaryBlobEndpoint string = !empty(blobServices) && contains(blobServices, 'containers') ? reference('Microsoft.Storage/storageAccounts/${storageAccount.name}', '2019-04-01').primaryEndpoints.blob : ''

@description('The principal ID of the system assigned identity.')
output systemAssignedPrincipalId string = systemAssignedIdentity && contains(storageAccount.identity, 'principalId') ? storageAccount.identity.principalId : ''

@description('The location the resource was deployed into.')
output location string = storageAccount.location

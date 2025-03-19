@description('Optional. The Resource Id of the Private DNS Zone where the Private Endpoint (if configured) A record will be registered.')
param azureBlobPrivateDnsZoneResourceId string = ''

param location string = resourceGroup().location

@description('Optional. The name of the compute gallery to create.')
param computeGalleryName string = ''

@maxLength(24)
@description('Required. Name of the Storage Account.')
param storageAccountName string

@minLength(3)
@maxLength(63)
@description('Required. Blob Container Name')
param blobContainerName string

@minLength(3)
@maxLength(128)
param managedIdentityName string

@allowed([
  'Storage'
  'StorageV2'
  'BlobStorage'
  'FileStorage'
  'BlockBlobStorage'
])
@description('Required. Type of Storage Account to create.')
param storageKind string

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
@description('Required. Storage Account Sku Name.')
param storageSkuName string

@allowed([
  'Premium'
  'Hot'
  'Cool'
])
@description('Conditional. Required if the Storage Account kind is set to BlobStorage. The access tier is used for billing. The "Premium" access tier is the default value for premium block blobs storage account type and it cannot be changed for the premium block blobs storage account type.')
param storageAccessTier string = 'Hot'

@description('Optional. The ResourceId of the subnet where the Private Endpoint will be created.')
param privateEndpointSubnetResourceId string = ''

@description('Optional. The Private Endpoint name to create for Blob Storage.')
param privateEndpointName string = ''

@description('Required. Indicates whether the storage account permits requests to be authorized with the account access key via Shared Key. If false, then all requests, including shared access signatures, must be authorized with Azure Active Directory (Azure AD). The default value is null, which is equivalent to true.')
param storageAllowSharedKeyAccess bool

@description('''Required. Whether or not public network access is allowed for this resource.
For security reasons it should be disabled; therefore, if you do not specify "storagePermittedIPs" or "storageServiceEndpointSubnetResourceIds" and you set "createPrivateEndpoint" to true,
then Public Network Access is automatically disabled.''')
@allowed([
  'Enabled'
  'Disabled'
])
param storageAllowPublicNetworkAccess string

@description('Optional. List of IPs and IP prefixes that are to be allowed through the Storage Account Firewall.')
param storagePermittedIPs array = []

@description('Optional. Array of subnet resource Ids where service endpoints are created for the storage account and permitted through the Storage Account Firewall.')
param storageServiceEndpointSubnetResourceIds array = []

@description('Optional. The SAS expiration period. DD.HH:MM:SS.')
param storageSASExpirationPeriod string = ''

@description('Optional. The log analytics workspace Id to where storage account diagnostics logs are sent.')
param logAnalyticsWorkspaceId string = ''

@description('Optional. The tags to apply to the resources created by this template.')
param tags object = {}

var ipRules = [for ip in storagePermittedIPs: {
  value: ip
  action: 'Allow'
}]

var virtualNetworkRules = [for subnetId in storageServiceEndpointSubnetResourceIds: {
  id: subnetId
  action: 'Allow'
}]

var roleDefinitionId = resourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1') // Storage Blob Data Reader

resource gallery 'Microsoft.Compute/galleries@2022-08-03' = {
  name: computeGalleryName
  location: location
  tags: tags[?'Microsoft.Compute/galleries'] ?? {}
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  tags: tags[?'Microsoft.Storage/storageAccounts'] ?? {}
  sku: {
    name: storageSkuName
  }
  kind: storageKind
  properties: {
    accessTier: storageAccessTier
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: storageAllowSharedKeyAccess
    minimumTlsVersion: 'TLS1_2'
    networkAcls: !(empty(ipRules)) || !(empty(storageServiceEndpointSubnetResourceIds)) ? {
      bypass: 'AzureServices'
      virtualNetworkRules: virtualNetworkRules
      ipRules: ipRules
      defaultAction: 'Deny'
    } : null
    publicNetworkAccess: storageAllowPublicNetworkAccess
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        blob: {
          enabled: true
        }
      }
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
    }
    sasPolicy: !empty(storageSASExpirationPeriod) ? {
      expirationAction: 'Log'
      sasExpirationPeriod: storageSASExpirationPeriod
    } : null
    
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    changeFeed: {
      enabled: true
      retentionInDays: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
      allowPermanentDelete: true
    }
    defaultServiceVersion: null
    deleteRetentionPolicy: {
      enabled: true
      days: 7
      allowPermanentDelete: true
    }
    isVersioningEnabled: true
    lastAccessTimeTrackingPolicy: {
      enable: true
      name: 'AccessTimeTracking'
      trackingGranularityInDays: 1
    }
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: blobContainerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2020-05-01' = if (!empty(privateEndpointSubnetResourceId)) {
  name: privateEndpointName
  location: location
  tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-08-01' = if (!empty(azureBlobPrivateDnsZoneResourceId)) {
  parent: privateEndpoint
  name: storageAccount.name
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'ipconfig1'
        properties: {
          privateDnsZoneId: azureBlobPrivateDnsZoneResourceId
        }
      }
    ]
  }
}

resource storageAccount_diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if(!empty(logAnalyticsWorkspaceId)) {
  name: '${storageAccountName}-diagnosticSettings'
  properties: {
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspaceId
  }
  scope: storageAccount
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
}

resource storageBlobReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedIdentityName, storageAccount.name, roleDefinitionId)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}

output storageAccountResourceId string    = storageAccount.id
output blobContainerName string           = blobContainer.name
output managedIdentityClientId string     = managedIdentity.properties.clientId
output managedIdentityResourceId string   = managedIdentity.id

targetScope = 'subscription'

import { publicNetworkAccessMode, servicePublicNetworkAccessMode, resolveNetworkAccess } from '../../deployments/shared/modules/orchestration/networking/functions.bicep'

// Keep legacy helper vectors while all entry/multi-family inputs remain explicit.
func explicitMode(mode publicNetworkAccessMode, privateEndpoint bool, hasRules bool) servicePublicNetworkAccessMode => resolveNetworkAccess(mode, privateEndpoint, hasRules).publicNetworkAccess == 'Disabled'
  ? 'Disabled'
  : resolveNetworkAccess(mode, privateEndpoint, hasRules).defaultAction == 'Allow'
    ? 'Enabled'
    : 'EnabledWithRestrictions'

param cases {
  mode: publicNetworkAccessMode
  privateEndpoint: bool
  ipRules: bool
  vnetRules: bool
  functionAppVnetRules: bool?
}[]

var subnetId = '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/test/subnets/private'
var otherSubnetId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/other-network/providers/Microsoft.Network/virtualNetworks/other/subnets/clients'
var allowedSubnets = [subnetId, ' ${toUpper(subnetId)} ', otherSubnetId]
var serviceCases = range(0, length(cases))

module vaults '../../deployments/shared/modules/orchestration/keyVaults/keyVaults.bicep' = [for i in serviceCases: {
  params: {
    resourceGroupName: 'network-tests'
    location: 'eastus'
    secretsKeyVaultName: 'kv-secrets-${i}'
    encryptionKeyVaultName: 'kv-encryption-${i}'
    keyVaultPublicNetworkAccess: explicitMode(cases[i].mode, cases[i].privateEndpoint, cases[i].ipRules || cases[i].vnetRules)
    keyVaultPrivateEndpoint: cases[i].privateEndpoint
    keyVaultPrivateEndpointSubnetResourceId: subnetId
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-RESOURCE-SUBRESOURCE'
    keyVaultPermittedIPs: cases[i].ipRules ? ['203.0.113.10'] : []
    keyVaultServiceEndpointSubnetResourceIds: cases[i].vnetRules ? allowedSubnets : []
    tags: {
      'Microsoft.KeyVault/vaults': { networkCase: 'vaults${i}' }
    }
  }
}]

module files '../../deployments/shared/modules/orchestration/fslogix/modules/azureFiles.bicep' = [for i in serviceCases: {
  scope: resourceGroup('network-tests')
  params: {
    appUpdateUserAssignedIdentityResourceId: ''
    filePrivateDnsZoneResourceId: ''
    deploymentUserAssignedIdentityClientId: ''
    deploymentVirtualMachineName: ''
    deploymentResourceGroupName: 'network-tests'
    domainJoinUserPassword: ''
    domainJoinUserPrincipalName: ''
    domainName: ''
    fslogixProfileEncryptionKeyNameConv: ''
    officeEncryptionKeyNameConv: ''
    encryptionKeyVaultUri: ''
    encryptionUserAssignedIdentityResourceId: ''
    fileShares: ['profile-containers']
    identitySolution: 'EntraId'
    keyManagementStorageAccounts: 'PlatformManaged'
    location: 'eastus'
    logAnalyticsWorkspaceId: ''
    ouPath: ''
    storagePublicNetworkAccess: explicitMode(cases[i].mode, cases[i].privateEndpoint, cases[i].ipRules || cases[i].vnetRules)
    storagePrivateEndpoint: cases[i].privateEndpoint
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-RESOURCE-SUBRESOURCE'
    storagePrivateEndpointSubnetResourceId: subnetId
    storagePermittedIPs: cases[i].ipRules ? ['203.0.113.10'] : []
    storageServiceEndpointSubnetResourceIds: cases[i].vnetRules ? allowedSubnets : []
    resourceGroupStorage: 'network-tests'
    shardingOptions: 'None'
    shareAdminGroups: []
    profileShareSizeInGB: 100
    shareUserGroups: []
    profileStorageAccountNamePrefix: 'files${i}'
    officeStorageAccountNamePrefix: 'office'
    storageCount: 1
    storageIndex: 1
    profileStorageTier: 'Standard'
    profileStorageRedundancy: 'LocallyRedundant'
    tags: {
      'Microsoft.Storage/storageAccounts': { networkCase: 'files${i}' }
    }
  }
}]

module apps '../../deployments/shared/modules/orchestration/functionApp/functionApp.bicep' = [for i in serviceCases: {
  scope: resourceGroup('network-tests')
  params: {
    blobPrivateDnsZoneResourceId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Network/privateDnsZones/privatelink.blob.example.test'
    queuePrivateDnsZoneResourceId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Network/privateDnsZones/privatelink.queue.example.test'
    tablePrivateDnsZoneResourceId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Network/privateDnsZones/privatelink.table.example.test'
    websitesPrivateDnsZoneResourceId: ''
    enableQueueStorage: i % 4 == 0
    encryptionKeyName: ''
    encryptionKeyVaultResourceId: ''
    functionAppDelegatedSubnetResourceId: ''
    functionAppName: 'function-${i}'
    functionAppAppSettings: []
    hostPoolResourceId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.DesktopVirtualization/hostPools/test'
    keyManagementStorageAccounts: 'PlatformManaged'
    location: 'eastus'
    storagePublicNetworkAccess: explicitMode(cases[i].mode, cases[i].privateEndpoint, cases[i].ipRules || cases[i].vnetRules)
    functionAppPublicNetworkAccess: explicitMode(cases[i].mode, cases[i].privateEndpoint, cases[i].ipRules || (cases[i].?functionAppVnetRules ?? cases[i].vnetRules))
    storagePrivateEndpoint: cases[i].privateEndpoint
    functionAppPrivateEndpoint: cases[i].privateEndpoint
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-RESOURCE-SUBRESOURCE'
    storagePrivateEndpointSubnetResourceId: subnetId
    functionAppPrivateEndpointSubnetResourceId: subnetId
    storagePermittedIPs: cases[i].ipRules ? [' 203.0.113.10 ', '198.51.100.0/24', '192.0.2.10/32', ' '] : []
    functionAppPermittedIPs: cases[i].ipRules ? [' 203.0.113.10 ', '198.51.100.0/24', '192.0.2.10/32', ' '] : []
    storageServiceEndpointSubnetResourceIds: cases[i].vnetRules ? allowedSubnets : []
    functionAppServiceEndpointSubnetResourceIds: (cases[i].?functionAppVnetRules ?? cases[i].vnetRules) ? allowedSubnets : []
    serverFarmId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Web/serverFarms/test'
    storageAccountName: 'functionstorage${i}'
    tags: {
      'Microsoft.Storage/storageAccounts': { networkCase: 'apps${i}' }
      'Microsoft.Web/sites': { networkCase: 'apps${i}' }
    }
  }
}]

module images '../../deployments/imageManagement/imageManagement.bicep' = [for (item, i) in cases: if (explicitMode(item.mode, item.privateEndpoint, item.ipRules || item.vnetRules) != 'EnabledWithRestrictions' || item.privateEndpoint || item.ipRules || item.vnetRules) {
  params: {
    location: 'eastus'
    deployImageBuildResourceGroup: false
    paasNetworking: {
      storage: {
        publicNetworkAccess: explicitMode(item.mode, item.privateEndpoint, item.ipRules || item.vnetRules)
        privateEndpoint: item.privateEndpoint
        permittedIPs: item.ipRules ? ['203.0.113.10'] : []
        serviceEndpointSubnetResourceIds: item.vnetRules ? allowedSubnets : []
      }
    }
    privateEndpointSubnetResourceIds: { sharedResources: subnetId }
    namingConvention: { workload: 'images${i}' }
    tags: {
      'Microsoft.Storage/storageAccounts': { networkCase: 'images${i}' }
    }
  }
}]

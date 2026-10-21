targetScope = 'subscription'

import { publicNetworkAccessMode } from '../../deployments/shared/modules/orchestration/networking/functions.bicep'

param cases {
  mode: publicNetworkAccessMode
  privateEndpoint: bool
  ipRules: bool
  vnetRules: bool
}[]

var subnetId = '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/test/subnets/private'
var serviceCases = filter(range(0, length(cases)), i => i % 2 == 0)

module vaults '../../deployments/shared/modules/orchestration/keyVaults/keyVaults.bicep' = [for i in serviceCases: {
  params: {
    resourceGroupName: 'network-tests'
    secretsKeyVaultName: 'kv-secrets-${i}'
    encryptionKeyVaultName: 'kv-encryption-${i}'
    paasPublicNetworkAccess: cases[i].mode
    privateEndpoint: cases[i].privateEndpoint
    privateEndpointSubnetResourceId: subnetId
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-RESOURCE-SUBRESOURCE'
    permittedIPs: cases[i].ipRules ? ['203.0.113.10'] : []
    tags: {
      'Microsoft.KeyVault/vaults': { networkCase: 'vaults${i}' }
    }
  }
}]

module files '../../deployments/shared/modules/orchestration/fslogix/modules/azureFiles.bicep' = [for i in serviceCases: {
  scope: resourceGroup('network-tests')
  params: {
    appUpdateUserAssignedIdentityResourceId: ''
    azureFilePrivateDnsZoneResourceId: ''
    deploymentUserAssignedIdentityClientId: ''
    deploymentVirtualMachineName: ''
    deploymentResourceGroupName: 'network-tests'
    domainJoinUserPassword: ''
    domainJoinUserPrincipalName: ''
    domainName: ''
    fslogixEncryptionKeyNameConv: ''
    encryptionKeyVaultUri: ''
    encryptionUserAssignedIdentityResourceId: ''
    fileShares: []
    identitySolution: 'EntraId'
    kerberosEncryptionType: 'AES256'
    keyManagementStorageAccounts: 'PlatformManaged'
    location: 'eastus'
    logAnalyticsWorkspaceId: ''
    ouPath: ''
    paasPublicNetworkAccess: cases[i].mode
    privateEndpoint: cases[i].privateEndpoint
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-RESOURCE-SUBRESOURCE'
    privateEndpointSubnetResourceId: subnetId
    permittedIPs: cases[i].ipRules ? ['203.0.113.10'] : []
    resourceGroupStorage: 'network-tests'
    shardingOptions: 'None'
    shareAdminGroups: []
    shareSizeInGB: 100
    shareUserGroups: []
    storageAccountNamePrefix: 'files${i}'
    storageCount: 1
    storageIndex: 1
    storageSku: 'Standard'
    storageRedundancy: 'LocallyRedundant'
    tags: {
      'Microsoft.Storage/storageAccounts': { networkCase: 'files${i}' }
    }
  }
}]

module apps '../../deployments/shared/modules/resourceModules/functionApp/functionApp.bicep' = [for i in serviceCases: {
  scope: resourceGroup('network-tests')
  params: {
    azureBlobPrivateDnsZoneResourceId: ''
    azureFunctionAppPrivateDnsZoneResourceId: ''
    encryptionKeyName: ''
    encryptionKeyVaultResourceId: ''
    functionAppDelegatedSubnetResourceId: ''
    functionAppName: 'function-${i}'
    functionAppAppSettings: []
    hostPoolResourceId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.DesktopVirtualization/hostPools/test'
    keyManagementStorageAccounts: 'PlatformManaged'
    location: 'eastus'
    paasPublicNetworkAccess: cases[i].mode
    privateEndpoint: cases[i].privateEndpoint
    privateEndpointNameConv: 'pe-RESOURCE-SUBRESOURCE'
    privateEndpointNICNameConv: 'nic-RESOURCE-SUBRESOURCE'
    privateEndpointSubnetResourceId: subnetId
    permittedIPs: cases[i].ipRules ? [' 203.0.113.10 ', '198.51.100.0/24', '192.0.2.10/32', ' '] : []
    serverFarmId: '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/network-tests/providers/Microsoft.Web/serverFarms/test'
    storageAccountName: 'functionstorage${i}'
    tags: {
      'Microsoft.Storage/storageAccounts': { networkCase: 'apps${i}' }
      'Microsoft.Web/sites': { networkCase: 'apps${i}' }
    }
  }
}]

module images '../../deployments/imageManagement/imageManagement.bicep' = [for (item, i) in cases: {
  params: {
    location: 'eastus'
    deployImageBuildResourceGroup: false
    paasPublicNetworkAccess: item.mode
    storageNetworkAccess: item.privateEndpoint ? 'PrivateEndpoint' : 'PublicEndpoint'
    privateEndpointSubnetResourceId: subnetId
    storagePermittedIPs: item.ipRules ? ['203.0.113.10'] : []
    storageServiceEndpointSubnetResourceIds: item.vnetRules ? [subnetId] : []
    namingConvention: { workload: 'images${i}' }
    tags: {
      'Microsoft.Storage/storageAccounts': { networkCase: 'images${i}' }
    }
  }
}]

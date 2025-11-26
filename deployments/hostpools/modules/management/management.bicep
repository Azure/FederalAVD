targetScope = 'subscription'

param appServicePlanName string
param azureKeyVaultPrivateDnsZoneResourceId string
param deploySecretsKeyVault bool
param enableQuotaManagement bool
param encryptionKeysKeyVaultName string
param deployEncryptionKeysKeyVault bool
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
#disable-next-line secure-secrets-in-params
param secretsKeyVaultName string
param keyVaultEnableSoftDelete bool
param keyVaultEnablePurgeProtection bool
param keyVaultRetentionInDays int
param location string
param logAnalyticsWorkspaceResourceId string
param privateEndpointSubnetResourceId string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param resourceGroupManagement string
param tags object
param deploymentSuffix string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param zoneRedundant bool

var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var privateEndpointVnetId = length(privateEndpointVnetName) < 37
  ? privateEndpointVnetName
  : uniqueString(privateEndpointVnetName)

var secretList = union(
  !empty(domainJoinUserPassword)
    ? [{ name: 'DomainJoinUserPassword', value: domainJoinUserPassword }]
    : [],
  !empty(domainJoinUserPrincipalName)
    ? [{ name: 'DomainJoinUserPrincipalName', value: domainJoinUserPrincipalName }]
    : [],
  !empty(virtualMachineAdminPassword)
    ? [{ name: 'VirtualMachineAdminPassword', value: virtualMachineAdminPassword }]
    : [],
  !empty(virtualMachineAdminUserName)
    ? [{ name: 'VirtualMachineAdminUserName', value: virtualMachineAdminUserName }]
    : []
)

module secretsKeyVault '../../../sharedModules/resources/key-vault/vault/main.bicep' = if (deploySecretsKeyVault && !empty(secretList)) {
  name: 'Secrets-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: secretsKeyVaultName
    diagnosticWorkspaceId: logAnalyticsWorkspaceResourceId
    enablePurgeProtection: keyVaultEnablePurgeProtection
    enableSoftDelete: keyVaultEnableSoftDelete
    softDeleteRetentionInDays: keyVaultRetentionInDays
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: true
    privateEndpoints: privateEndpoint && !empty(privateEndpointSubnetResourceId)
      ? [
          {
            customNetworkInterfaceName: replace(
              replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', secretsKeyVaultName),
              'VNETID',
              privateEndpointVnetId
            )
            name: replace(
              replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', secretsKeyVaultName),
              'VNETID',
              privateEndpointVnetId
            )
            privateDnsZoneGroup: empty(azureKeyVaultPrivateDnsZoneResourceId)
              ? null
              : {
                  privateDNSResourceIds: [
                    azureKeyVaultPrivateDnsZoneResourceId
                  ]
                }
            service: 'vault'
            subnetResourceId: privateEndpointSubnetResourceId
            tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
          }
        ]
      : null
    secrets: {
      secureList: secretList
    }
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
    vaultSku: 'standard'
  }
}

module encryptionKeyVault '../../../sharedModules/resources/key-vault/vault/main.bicep' = if (deployEncryptionKeysKeyVault) {
  name: 'Encryption-Keys-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: encryptionKeysKeyVaultName
    diagnosticWorkspaceId:logAnalyticsWorkspaceResourceId
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultRetentionInDays
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: true
    enableVaultForTemplateDeployment: false
    privateEndpoints: privateEndpoint && !empty(privateEndpointSubnetResourceId)
      ? [
          {
            customNetworkInterfaceName: replace(
              replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', encryptionKeysKeyVaultName),
              'VNETID',
              privateEndpointVnetId
            )
            name: replace(
              replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', encryptionKeysKeyVaultName),
              'VNETID',
              privateEndpointVnetId
            )
            privateDnsZoneGroup: empty(azureKeyVaultPrivateDnsZoneResourceId)
              ? null
              : {
                  privateDNSResourceIds: [
                    azureKeyVaultPrivateDnsZoneResourceId
                  ]
                }
            service: 'vault'
            subnetResourceId: privateEndpointSubnetResourceId
            tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
          }
        ]
      : null
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
    vaultSku: 'premium'
  }
}

module hostingPlan 'modules/functionAppHostingPlan.bicep' = if (enableQuotaManagement) {
  name: 'FunctionAppHostingPlan-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    functionAppKind: 'functionApp'
    hostingPlanType: 'FunctionsPremium'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceResourceId
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_P1v3'
    tags: tags[?'Microsoft.Web/serverfarms'] ?? {}
    zoneRedundant: zoneRedundant
  }
}

output appServicePlanId string = enableQuotaManagement ? hostingPlan!.outputs.hostingPlanId : ''
output encryptionKeyVaultResourceId string = deployEncryptionKeysKeyVault ? encryptionKeyVault!.outputs.resourceId : ''
output encryptionKeyVaultUri string = deployEncryptionKeysKeyVault ? encryptionKeyVault!.outputs.uri : ''

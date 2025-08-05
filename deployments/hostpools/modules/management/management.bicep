targetScope = 'subscription'

param appServicePlanName string
param azureKeyVaultPrivateDnsZoneResourceId string
param azureMonitorPrivateLinkScopeResourceId string
param dataCollectionEndpointName string
param deploySecretsKeyVault bool
param enableMonitoring bool
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
param logAnalyticsWorkspaceName string
param logAnalyticsWorkspaceRetention int
param logAnalyticsWorkspaceSku string
param privateEndpointSubnetResourceId string
param privateEndpoint bool
param privateEndpointNameConv string
param privateEndpointNICNameConv string
param resourceGroupManagement string
param tags object
param timeStamp string
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
  name: 'Secrets_KeyVault_${timeStamp}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: secretsKeyVaultName
    diagnosticWorkspaceId: enableMonitoring ? logAnalyticsWorkspace.outputs.resourceId : ''
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
  name: 'Encryption_Keys_KeyVault_${timeStamp}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: encryptionKeysKeyVaultName
    diagnosticWorkspaceId: enableMonitoring ? logAnalyticsWorkspace.outputs.resourceId : ''
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

module logAnalyticsWorkspace 'modules/logAnalyticsWorkspace.bicep' = if (enableMonitoring) {
  scope: resourceGroup(resourceGroupManagement)
  name: 'LogAnalytics_${timeStamp}'
  params: {
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    logAnalyticsWorkspaceRetention: logAnalyticsWorkspaceRetention
    logAnalyticsWorkspaceSku: logAnalyticsWorkspaceSku
    location: location
    tags: tags[?'Microsoft.OperationalInsights/workspaces'] ?? {}
  }
}

// Data Collection Rule for AVD Insights required for the Azure Monitor Agent
module avdInsightsDataCollectionRules 'modules/avdInsightsDataCollectionRules.bicep' = if (enableMonitoring) {
  name: 'AVDInsights_DataCollectionRule_${timeStamp}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    dataCollectionEndpointId: dataCollectionEndpoint.outputs.resourceId
    logAWorkspaceResourceId: enableMonitoring ? logAnalyticsWorkspace.outputs.resourceId : ''
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
  }
}

// Data Collection Rule for VM Insights required for the Azure Monitor Agent
module vmInsightsDataCollectionRules 'modules/vmInsightsDataCollectionRules.bicep' = if (enableMonitoring) {
  name: 'VMInsights_DataCollectionRule_${timeStamp}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    dataCollectionEndpointId: dataCollectionEndpoint.outputs.resourceId
    logAWorkspaceResourceId: enableMonitoring ? logAnalyticsWorkspace.outputs.resourceId : ''
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionRules'] ?? {}
  }
}

module dataCollectionEndpoint 'modules/dataCollectionEndpoint.bicep' = if (enableMonitoring) {
  name: 'DataCollectionEndpoint_${timeStamp}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    location: location
    tags: tags[?'Microsoft.Insights/dataCollectionEndpoints'] ?? {}
    name: dataCollectionEndpointName
    publicNetworkAccess: empty(azureMonitorPrivateLinkScopeResourceId) ? 'Enabled' : 'Disabled'
  }
}

module updatePrivateLinkScope '../common/privateLinkScopes/get-PrivateLinkScope.bicep' = if (enableMonitoring && !empty(azureMonitorPrivateLinkScopeResourceId)) {
  name: 'PrivateLlinkScope-${timeStamp}'
  params: {
    privateLinkScopeResourceId: azureMonitorPrivateLinkScopeResourceId
    scopedResourceIds: [
      logAnalyticsWorkspace.outputs.resourceId
      dataCollectionEndpoint.outputs.resourceId
    ]
    timeStamp: timeStamp
  }
}

module hostingPlan 'modules/functionAppHostingPlan.bicep' = if (enableQuotaManagement) {
  name: 'FunctionAppHostingPlan_${timeStamp}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    functionAppKind: 'functionApp'
    hostingPlanType: 'FunctionsPremium'
    logAnalyticsWorkspaceId: enableMonitoring ? logAnalyticsWorkspace.outputs.resourceId : ''
    location: location
    name: appServicePlanName
    planPricing: 'PremiumV3_P1v3'
    tags: tags[?'Microsoft.Web/serverfarms'] ?? {}
    zoneRedundant: zoneRedundant
  }
}

output appServicePlanId string = enableQuotaManagement ? hostingPlan.outputs.hostingPlanId : ''
output avdInsightsDataCollectionRulesResourceId string = enableMonitoring
  ? avdInsightsDataCollectionRules.outputs.dataCollectionRulesId
  : ''
output dataCollectionEndpointResourceId string = enableMonitoring ? dataCollectionEndpoint.outputs.resourceId : ''
output logAnalyticsWorkspaceResourceId string = enableMonitoring ? logAnalyticsWorkspace.outputs.resourceId : ''
output vmInsightsDataCollectionRulesResourceId string = enableMonitoring
  ? vmInsightsDataCollectionRules.outputs.dataCollectionRulesId
  : ''
output encryptionKeyVaultResourceId string = deployEncryptionKeysKeyVault ? encryptionKeyVault.outputs.resourceId : ''
output encryptionKeyVaultUri string = deployEncryptionKeysKeyVault ? encryptionKeyVault.outputs.uri : ''

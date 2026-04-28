targetScope = 'subscription'

param azureKeyVaultPrivateDnsZoneResourceId string
param deploySecretsKeyVault bool
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

var privateEndpointVnetName = !empty(privateEndpointSubnetResourceId) && privateEndpoint
  ? split(privateEndpointSubnetResourceId, '/')[8]
  : ''

var privateEndpointVnetId = length(privateEndpointVnetName) < 37
  ? privateEndpointVnetName
  : uniqueString(privateEndpointVnetName)

var secretList = union(
  !empty(domainJoinUserPassword) ? [{ name: 'DomainJoinUserPassword', value: domainJoinUserPassword }] : [],
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

var deploySecretsKv = deploySecretsKeyVault && !empty(secretList)
var deploySecretsKvPe = deploySecretsKv && privateEndpoint && !empty(privateEndpointSubnetResourceId)
var deployEncryptionKvPe = deployEncryptionKeysKeyVault && privateEndpoint && !empty(privateEndpointSubnetResourceId)

// ─── Secrets Key Vault ─────────────────────────────────────────────────────────
module secretsKeyVault '../../../../.common/bicepModules/keyVault/vaults/deploy.bicep' = if (deploySecretsKv) {
  name: 'Secrets-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: secretsKeyVaultName
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
    sku: 'standard'
    enableSoftDelete: keyVaultEnableSoftDelete
    softDeleteRetentionInDays: keyVaultRetentionInDays
    enablePurgeProtection: keyVaultEnablePurgeProtection
    enabledForTemplateDeployment: true
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: privateEndpoint ? 'Deny' : 'Allow'
    }
  }
}

module secretsKeyVault_pe '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deploySecretsKvPe) {
  name: 'Secrets-KV-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', secretsKeyVaultName),
      'VNETID',
      privateEndpointVnetId
    )
    customNetworkInterfaceName: replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', secretsKeyVaultName),
      'VNETID',
      privateEndpointVnetId
    )
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: secretsKeyVault!.outputs.resourceId
    groupId: 'vault'
    privateDNSZoneIds: !empty(azureKeyVaultPrivateDnsZoneResourceId) ? [azureKeyVaultPrivateDnsZoneResourceId] : []
  }
}

module secrets '../../../../.common/bicepModules/keyVault/vaults/secrets/deploy.bicep' = [
  for secret in secretList: if (deploySecretsKv) {
    name: 'Secret-${secret.name}-${deploymentSuffix}'
    scope: resourceGroup(resourceGroupManagement)
    params: {
      keyVaultName: secretsKeyVaultName
      name: secret.name
      value: secret.value
    }
    dependsOn: [secretsKeyVault]
  }
]

// ─── Encryption Keys Key Vault ─────────────────────────────────────────────────
module encryptionKeyVault '../../../../.common/bicepModules/keyVault/vaults/deploy.bicep' = if (deployEncryptionKeysKeyVault) {
  name: 'Encryption-Keys-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: encryptionKeysKeyVaultName
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
    sku: 'premium'
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultRetentionInDays
    enablePurgeProtection: true
    enabledForDiskEncryption: true
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    publicNetworkAccess: privateEndpoint ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: privateEndpoint ? 'Deny' : 'Allow'
    }
  }
}

module encryptionKeyVault_pe '../../../../.common/bicepModules/network/privateEndpoints/deploy.bicep' = if (deployEncryptionKvPe) {
  name: 'Encryption-KV-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupManagement)
  params: {
    name: replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', encryptionKeysKeyVaultName),
      'VNETID',
      privateEndpointVnetId
    )
    customNetworkInterfaceName: replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', encryptionKeysKeyVaultName),
      'VNETID',
      privateEndpointVnetId
    )
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: encryptionKeyVault!.outputs.resourceId
    groupId: 'vault'
    privateDNSZoneIds: !empty(azureKeyVaultPrivateDnsZoneResourceId) ? [azureKeyVaultPrivateDnsZoneResourceId] : []
  }
}

output encryptionKeyVaultResourceId string = deployEncryptionKeysKeyVault ? encryptionKeyVault!.outputs.resourceId : ''
output encryptionKeyVaultUri string = deployEncryptionKeysKeyVault ? encryptionKeyVault!.outputs.uri : ''

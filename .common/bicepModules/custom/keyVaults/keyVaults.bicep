targetScope = 'subscription'
// Shared module: deploys AVD Secrets Key Vault and/or Encryption Key Vault into an existing resource group.
// Called by both the standalone Security deployment and the hostpool inline fallback.
// The caller is responsible for creating the resource group before calling this module.
param resourceGroupName string
param azureKeyVaultPrivateDnsZoneResourceId string = ''
param deploySecretsKeyVault bool = true
#disable-next-line secure-secrets-in-params
param secretsKeyVaultName string
@secure()
param domainJoinUserPassword string = ''
@secure()
param domainJoinUserPrincipalName string = ''
param keyVaultEnableSoftDelete bool = true
param keyVaultEnablePurgeProtection bool = true
param keyVaultRetentionInDays int = 90
param logAnalyticsWorkspaceResourceId string = ''
param privateEndpoint bool = false
param privateEndpointSubnetResourceId string = ''
param privateEndpointNameConv string = ''
param privateEndpointNICNameConv string = ''
param tags object = {}
param deploymentSuffix string
@secure()
param virtualMachineAdminPassword string = ''
@secure()
param virtualMachineAdminUserName string = ''

param deployEncryptionKeyVault bool = true
param encryptionKeyVaultName string

@description('Optional. Array of permitted IP addresses or CIDR blocks allowed through the firewall of all Key Vaults deployed by this module.')
param permittedIPs array = []

@description('Optional. When true, the encryption key vault is deployed with public network access enabled and all IP-based firewall restrictions cleared, regardless of the privateEndpoint setting. Required when CMK is configured on Recovery Services Vault (RSV does not use the AzureServices trusted service bypass, and its backup IPs are regional/dynamic so IP restrictions are not feasible). Only set this when you explicitly accept the tradeoff of an internet-reachable encryption key vault without IP restrictions.')
param encryptionKeyVaultForcePublicAccess bool = false

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

var deploySecretsKv = deploySecretsKeyVault
var deploySecretsKvPe = deploySecretsKv && privateEndpoint && !empty(privateEndpointSubnetResourceId)
var deployEncryptionKvPe = deployEncryptionKeyVault && privateEndpoint && !empty(privateEndpointSubnetResourceId)

// Resolve publicNetworkAccess for each vault. When PE is used and no IPs are permitted, public access
// is disabled — the PE becomes the sole access path. IP allowances or an explicit override keep it open.
var kvPublicAccessDisabled = privateEndpoint && empty(permittedIPs)
var secretsKvPublicNetworkAccess = kvPublicAccessDisabled ? 'Disabled' : 'Enabled'
// Encryption KV can be forced open (Enabled) to support RSV CMK, which requires unrestricted public access.
// In all other PE+no-IP scenarios it is private-only, matching the secrets KV.
var encryptionKvPublicNetworkAccess = encryptionKeyVaultForcePublicAccess ? 'Enabled' : (kvPublicAccessDisabled ? 'Disabled' : 'Enabled')

// ─── Secrets Key Vault ─────────────────────────────────────────────────────────

module secretsKeyVault '../../keyVault/vaults/deploy.bicep' = if (deploySecretsKv) {
  name: 'Secrets-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
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
    permittedIPs: permittedIPs
    publicNetworkAccess: secretsKvPublicNetworkAccess
  }
}

module secretsKeyVault_pe '../../network/privateEndpoints/deploy.bicep' = if (deploySecretsKvPe) {
  name: 'Secrets-KV-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
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

module secrets '../../keyVault/vaults/secrets/deploy.bicep' = [
  for secret in secretList: if (deploySecretsKv) {
    name: 'Secret-${secret.name}-${deploymentSuffix}'
    scope: resourceGroup(resourceGroupName)
    params: {
      keyVaultName: secretsKeyVaultName
      name: secret.name
      value: secret.value
    }
    dependsOn: [secretsKeyVault]
  }
]

// ─── Encryption Key Vault ──────────────────────────────────────────────────────

module encryptionKeyVault '../../keyVault/vaults/deploy.bicep' = if (deployEncryptionKeyVault) {
  name: 'Encryption-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: encryptionKeyVaultName
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
    sku: 'premium'
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultRetentionInDays
    enablePurgeProtection: true
    enabledForDiskEncryption: true
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    permittedIPs: encryptionKeyVaultForcePublicAccess ? [] : permittedIPs
    publicNetworkAccess: encryptionKvPublicNetworkAccess
  }
}

module encryptionKeyVault_pe '../../network/privateEndpoints/deploy.bicep' = if (deployEncryptionKvPe) {
  name: 'Encryption-KV-PE-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: replace(
      replace(replace(privateEndpointNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', encryptionKeyVaultName),
      'VNETID',
      privateEndpointVnetId
    )
    customNetworkInterfaceName: replace(
      replace(replace(privateEndpointNICNameConv, 'SUBRESOURCE', 'vault'), 'RESOURCE', encryptionKeyVaultName),
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

// ─── Outputs ───────────────────────────────────────────────────────────────────

output secretsKeyVaultResourceId string = deploySecretsKv ? secretsKeyVault!.outputs.resourceId : ''
output encryptionKeyVaultResourceId string = deployEncryptionKeyVault ? encryptionKeyVault!.outputs.resourceId : ''
output encryptionKeyVaultUri string = deployEncryptionKeyVault ? encryptionKeyVault!.outputs.uri : ''

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
param secretsKeyVaultEnableSoftDelete bool = true
param secretsKeyVaultEnablePurgeProtection bool = true
param secretsKeyVaultRetentionInDays int = 90

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
@description('Optional. Soft delete retention days specifically for the Encryption Key Vault. Defaults to keyVaultRetentionInDays.')
@minValue(7)
@maxValue(90)
param encryptionKeyVaultRetentionInDays int = secretsKeyVaultRetentionInDays

@description('Optional. Array of permitted IP addresses or CIDR blocks allowed through the firewall of all Key Vaults deployed by this module.')
param permittedIPs array = []

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
var encryptionKvPublicNetworkAccess = kvPublicAccessDisabled ? 'Disabled' : 'Enabled'

var ipRules = [for ip in permittedIPs: { value: ip, action: 'Allow' }]
var kvHasNetworkRestrictions = privateEndpoint || !empty(permittedIPs)

// Secrets KV uses AzureServices bypass because enabledForTemplateDeployment is true.
// defaultAction falls back to 'Allow' only when no network restrictions are configured (dev/open scenario).
var secretsKvNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: kvHasNetworkRestrictions ? 'Deny' : 'Allow'
  ipRules: ipRules
}

var encryptionKvNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: kvHasNetworkRestrictions ? 'Deny' : 'Allow'
  ipRules: ipRules
}

// ─── Secrets Key Vault ─────────────────────────────────────────────────────────

module secretsKeyVault '../../keyVault/vaults/deploy.bicep' = if (deploySecretsKv) {
  name: 'Secrets-KeyVault-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: secretsKeyVaultName
    tags: tags[?'Microsoft.KeyVault/vaults'] ?? {}
    sku: 'standard'
    enableSoftDelete: secretsKeyVaultEnableSoftDelete
    softDeleteRetentionInDays: secretsKeyVaultRetentionInDays
    enablePurgeProtection: secretsKeyVaultEnablePurgeProtection
    enabledForTemplateDeployment: true
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    networkAcls: secretsKvNetworkAcls
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
    softDeleteRetentionInDays: encryptionKeyVaultRetentionInDays
    enablePurgeProtection: true
    enabledForDiskEncryption: true
    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId)
      ? { workspaceId: logAnalyticsWorkspaceResourceId }
      : null
    networkAcls: encryptionKvNetworkAcls
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

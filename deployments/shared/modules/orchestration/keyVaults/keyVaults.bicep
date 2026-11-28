metadata name = 'Shared Key Vault orchestration'
metadata description = 'Deploys optional credential and encryption vaults in an existing resource group, with optional credential secrets, diagnostics, firewall allowances, and private endpoints.'

targetScope = 'subscription'
import { servicePublicNetworkAccessMode, resolveNetworkAccess, serviceEndpointSubnetIds } from '../networking/functions.bicep'

// Shared module: deploys AVD Secrets Key Vault and/or Encryption Key Vault into an existing resource group.
// Called by both the standalone Security deployment and the hostpool inline fallback.
// The caller is responsible for creating the resource group before calling this module.
@description('Required. Name of the existing target resource group in the deployment subscription.')
param resourceGroupName string
@description('Required. Azure region for both vaults, independent of resource group metadata location. Private endpoints use their subnet virtual network region.')
param location string
@description('Optional. Resource ID of an existing Key Vault private DNS zone; empty omits the private endpoint DNS zone group.')
param vaultPrivateDnsZoneResourceId string = ''
@description('Optional. Whether to deploy the credential vault and any supplied nonempty credential secrets.')
param deploySecretsKeyVault bool = true
@description('Required. Name of the credential vault to create when deploySecretsKeyVault is true.')
#disable-next-line secure-secrets-in-params
param secretsKeyVaultName string
@secure()
@description('Optional. Domain account password to store as a credential secret; empty skips this secret.')
param domainJoinUserPassword string = ''
@secure()
@description('Optional. Domain account UPN to store as a credential secret; empty skips this secret.')
param domainJoinUserPrincipalName string = ''
@description('Optional. Whether to enable soft delete on the credential vault.')
param secretsKeyVaultEnableSoftDelete bool = true
@description('Optional. Whether to enable purge protection on the credential vault.')
param secretsKeyVaultEnablePurgeProtection bool = true
@description('Optional. Soft-delete retention interval in days for the credential vault.')
param secretsKeyVaultRetentionInDays int = 90

@description('Optional. Resource ID of an existing Log Analytics workspace; empty omits optional diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''
@description('Optional. Whether to create Key Vault private endpoints. Public access is controlled separately by keyVaultPublicNetworkAccess.')
param keyVaultPrivateEndpoint bool = false
@description('Optional. Resource ID of the existing subnet for private endpoints; required when endpoint creation is selected.')
param keyVaultPrivateEndpointSubnetResourceId string = ''
@description('Optional. Private endpoint name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNameConv string = ''
@description('Optional. Private endpoint NIC name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNICNameConv string = ''
@description('Optional. Key-value pairs to apply as tags to the Azure resources.')
param tags object = {}
@secure()
@description('Optional. Local administrator password to store as a credential secret; empty skips this secret.')
param virtualMachineAdminPassword string = ''
@secure()
@description('Optional. Local administrator account name to store as a credential secret; empty skips this secret.')
param virtualMachineAdminUserName string = ''

@description('Optional. Whether to deploy the Premium encryption vault with soft delete and purge protection.')
param deployEncryptionKeyVault bool = true
@description('Required. Name of the encryption vault to create when deployEncryptionKeyVault is true.')
param encryptionKeyVaultName string
@description('Optional. Soft delete retention days specifically for the Encryption Key Vault. Defaults to keyVaultRetentionInDays.')
@minValue(7)
@maxValue(90)
param encryptionKeyVaultRetentionInDays int = secretsKeyVaultRetentionInDays

@description('Optional. Array of permitted IP addresses or CIDR blocks allowed through the firewall of all Key Vaults deployed by this module.')
param keyVaultPermittedIPs array = []

@description('Optional. Allowed subnet IDs for both new vaults with existing Microsoft.KeyVault service endpoints. Does not modify subnets.')
param keyVaultServiceEndpointSubnetResourceIds string[] = []

@description('Optional. One explicit public-access policy for both newly created vaults. IP/subnet rules and AzureServices bypass are retained in all modes.')
param keyVaultPublicNetworkAccess servicePublicNetworkAccessMode = 'Disabled'

var privateEndpointVnetName = !empty(keyVaultPrivateEndpointSubnetResourceId) && keyVaultPrivateEndpoint
  ? split(keyVaultPrivateEndpointSubnetResourceId, '/')[8]
  : ''
import { privateEndpointName } from '../naming/internal.bicep'

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
var deploySecretsKvPe = deploySecretsKv && keyVaultPrivateEndpoint && !empty(keyVaultPrivateEndpointSubnetResourceId)
var deployEncryptionKvPe = deployEncryptionKeyVault && keyVaultPrivateEndpoint && !empty(keyVaultPrivateEndpointSubnetResourceId)
var deployKeyVaultPrivateEndpoint = deploySecretsKvPe || deployEncryptionKvPe

resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployKeyVaultPrivateEndpoint) {
  name: split(keyVaultPrivateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(
    split(keyVaultPrivateEndpointSubnetResourceId, '/')[2],
    split(keyVaultPrivateEndpointSubnetResourceId, '/')[4]
  )
}

// AzureServices bypass supports template deployment and encryption integrations. It remains
// configured even with public access disabled; Disabled is not a private-only guarantee for trusted services.
var effectivePermittedIPs = filter(keyVaultPermittedIPs, ip => !empty(trim(ip)))
var keyVaultSubnetIds = serviceEndpointSubnetIds(keyVaultServiceEndpointSubnetResourceIds)
var networkAccess = resolveNetworkAccess(keyVaultPublicNetworkAccess, keyVaultPrivateEndpoint, !empty(effectivePermittedIPs) || !empty(keyVaultSubnetIds))
var secretsKvPublicNetworkAccess = networkAccess.publicNetworkAccess
var encryptionKvPublicNetworkAccess = networkAccess.publicNetworkAccess

var ipRules = [for ip in effectivePermittedIPs: { value: ip, action: 'Allow' }]
var keyVaultVnetRules = [for id in keyVaultSubnetIds: { id: id, ignoreMissingVnetServiceEndpoint: false }]

// Secrets KV uses AzureServices bypass because enabledForTemplateDeployment is true.
var secretsKvNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: networkAccess.defaultAction
  ipRules: ipRules
  virtualNetworkRules: keyVaultVnetRules
}

var encryptionKvNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: networkAccess.defaultAction
  ipRules: ipRules
  virtualNetworkRules: keyVaultVnetRules
}

// ─── Secrets Key Vault ─────────────────────────────────────────────────────────

module secretsKeyVault '../../resourceModules/keyVault/vaults/deploy.bicep' = if (deploySecretsKv) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: secretsKeyVaultName
    location: location
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

module secretsKeyVault_pe '../../resourceModules/network/privateEndpoints/deploy.bicep' = if (deploySecretsKvPe) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: privateEndpointName(privateEndpointNameConv, secretsKeyVaultName, 'vault', privateEndpointVnetName)
    customNetworkInterfaceName: privateEndpointName(privateEndpointNICNameConv, secretsKeyVaultName, 'vault', privateEndpointVnetName)
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    location: privateEndpointVirtualNetwork!.location
    subnetResourceId: keyVaultPrivateEndpointSubnetResourceId
    privateLinkServiceId: secretsKeyVault!.outputs.resourceId
    groupId: 'vault'
    privateDNSZoneIds: !empty(vaultPrivateDnsZoneResourceId) ? [vaultPrivateDnsZoneResourceId] : []
  }
}

module secrets '../../resourceModules/keyVault/vaults/secrets/deploy.bicep' = [
  for secret in secretList: if (deploySecretsKv) {
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

module encryptionKeyVault '../../resourceModules/keyVault/vaults/deploy.bicep' = if (deployEncryptionKeyVault) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: encryptionKeyVaultName
    location: location
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

module encryptionKeyVault_pe '../../resourceModules/network/privateEndpoints/deploy.bicep' = if (deployEncryptionKvPe) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: privateEndpointName(privateEndpointNameConv, encryptionKeyVaultName, 'vault', privateEndpointVnetName)
    customNetworkInterfaceName: privateEndpointName(privateEndpointNICNameConv, encryptionKeyVaultName, 'vault', privateEndpointVnetName)
    tags: tags[?'Microsoft.Network/privateEndpoints'] ?? {}
    location: privateEndpointVirtualNetwork!.location
    subnetResourceId: keyVaultPrivateEndpointSubnetResourceId
    privateLinkServiceId: encryptionKeyVault!.outputs.resourceId
    groupId: 'vault'
    privateDNSZoneIds: !empty(vaultPrivateDnsZoneResourceId) ? [vaultPrivateDnsZoneResourceId] : []
  }
}

// ─── Outputs ───────────────────────────────────────────────────────────────────

@description('Created credential vault resource ID, or an empty string when credential vault deployment is disabled.')
output secretsKeyVaultResourceId string = deploySecretsKv ? secretsKeyVault!.outputs.resourceId : ''

@description('Created encryption vault resource ID, or an empty string when encryption vault deployment is disabled.')
output encryptionKeyVaultResourceId string = deployEncryptionKeyVault ? encryptionKeyVault!.outputs.resourceId : ''

@description('Created encryption vault URI, or an empty string when encryption vault deployment is disabled.')
output encryptionKeyVaultUri string = deployEncryptionKeyVault ? encryptionKeyVault!.outputs.uri : ''

metadata name = 'Shared Key Vault orchestration'
metadata description = 'Deploys optional credential and encryption vaults in an existing resource group, with optional credential secrets, diagnostics, firewall allowances, and private endpoints.'

targetScope = 'subscription'
import { publicNetworkAccessMode, resolveNetworkAccess } from '../networking/functions.bicep'
// Shared module: deploys AVD Secrets Key Vault and/or Encryption Key Vault into an existing resource group.
// Called by both the standalone Security deployment and the hostpool inline fallback.
// The caller is responsible for creating the resource group before calling this module.
@description('Required. Name of the existing target resource group in the deployment subscription.')
param resourceGroupName string
@description('Optional. Resource ID of an existing Key Vault private DNS zone; empty omits the private endpoint DNS zone group.')
param azureKeyVaultPrivateDnsZoneResourceId string = ''
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
@description('Optional. Whether to create private endpoints. Public access is controlled separately by paasPublicNetworkAccess.')
param privateEndpoint bool = false
@description('Optional. Resource ID of the existing subnet for private endpoints; required when endpoint creation is selected.')
param privateEndpointSubnetResourceId string = ''
@description('Optional. Private endpoint name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNameConv string = ''
@description('Optional. Private endpoint NIC name pattern using RESOURCE, SUBRESOURCE, and VNETID substitution tokens.')
param privateEndpointNICNameConv string = ''
@description('Optional. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
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
param permittedIPs array = []

@description('Optional. Public-access mode for both vaults. Auto preserves legacy behavior; configured IP rules and AzureServices bypass are retained in all modes.')
param paasPublicNetworkAccess publicNetworkAccessMode = 'Auto'

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
var deployKeyVaultPrivateEndpoint = deploySecretsKvPe || deployEncryptionKvPe

resource privateEndpointVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = if (deployKeyVaultPrivateEndpoint) {
  name: split(privateEndpointSubnetResourceId, '/')[8]
  scope: resourceGroup(
    split(privateEndpointSubnetResourceId, '/')[2],
    split(privateEndpointSubnetResourceId, '/')[4]
  )
}

// AzureServices bypass supports template deployment and encryption integrations. It remains
// configured even with public access disabled; Disabled is not a private-only guarantee for trusted services.
var effectivePermittedIPs = filter(permittedIPs, ip => !empty(trim(ip)))
var networkAccess = resolveNetworkAccess(paasPublicNetworkAccess, privateEndpoint, !empty(effectivePermittedIPs))
var secretsKvPublicNetworkAccess = networkAccess.publicNetworkAccess
var encryptionKvPublicNetworkAccess = networkAccess.publicNetworkAccess

var ipRules = [for ip in effectivePermittedIPs: { value: ip, action: 'Allow' }]

// Secrets KV uses AzureServices bypass because enabledForTemplateDeployment is true.
var secretsKvNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: networkAccess.defaultAction
  ipRules: ipRules
}

var encryptionKvNetworkAcls = {
  bypass: 'AzureServices'
  defaultAction: networkAccess.defaultAction
  ipRules: ipRules
}

// ─── Secrets Key Vault ─────────────────────────────────────────────────────────

module secretsKeyVault '../../resourceModules/keyVault/vaults/deploy.bicep' = if (deploySecretsKv) {
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

module secretsKeyVault_pe '../../resourceModules/network/privateEndpoints/deploy.bicep' = if (deploySecretsKvPe) {
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
    location: privateEndpointVirtualNetwork!.location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: secretsKeyVault!.outputs.resourceId
    groupId: 'vault'
    privateDNSZoneIds: !empty(azureKeyVaultPrivateDnsZoneResourceId) ? [azureKeyVaultPrivateDnsZoneResourceId] : []
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
    location: privateEndpointVirtualNetwork!.location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceId: encryptionKeyVault!.outputs.resourceId
    groupId: 'vault'
    privateDNSZoneIds: !empty(azureKeyVaultPrivateDnsZoneResourceId) ? [azureKeyVaultPrivateDnsZoneResourceId] : []
  }
}

// ─── Outputs ───────────────────────────────────────────────────────────────────

@description('Created credential vault resource ID, or an empty string when credential vault deployment is disabled.')
output secretsKeyVaultResourceId string = deploySecretsKv ? secretsKeyVault!.outputs.resourceId : ''
@description('Created encryption vault resource ID, or an empty string when encryption vault deployment is disabled.')
output encryptionKeyVaultResourceId string = deployEncryptionKeyVault ? encryptionKeyVault!.outputs.resourceId : ''
@description('Created encryption vault URI, or an empty string when encryption vault deployment is disabled.')
output encryptionKeyVaultUri string = deployEncryptionKeyVault ? encryptionKeyVault!.outputs.uri : ''

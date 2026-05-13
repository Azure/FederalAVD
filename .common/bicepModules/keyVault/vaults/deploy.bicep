import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

@allowed(['standard', 'premium'])
@description('Standard supports software-protected keys. Premium adds HSM-backed key support.')
param sku string = 'premium'

param enableRbacAuthorization bool = true
param enableSoftDelete bool = true
param softDeleteRetentionInDays int = 90
param enablePurgeProtection bool = true

@description('Allow ARM to retrieve secrets during deployments. Required if using KV secrets in parameter files.')
param enabledForDeployment bool = false
param enabledForTemplateDeployment bool = false
@description('Allow disk encryption operations (Azure Disk Encryption / Disk Encryption Sets) to access the vault.')
param enabledForDiskEncryption bool = false

@description('Optional. Whether this vault is accessed via a private endpoint. When true and no permittedIPs are provided, public network access is disabled.')
param privateEndpoint bool = false

@description('Optional. Array of permitted IP addresses or CIDR blocks. When provided, public access is enabled with a deny-by-default firewall.')
param permittedIPs array = []

param diagnosticSettings diagnosticSettingsType?

// AzureServices bypass is required when vault is used for deployment, template deployment, or disk encryption
var requiresAzureServicesBypass = enabledForDeployment || enabledForTemplateDeployment || enabledForDiskEncryption

var kvIpRules = [for ip in permittedIPs: { value: ip, action: 'Allow' }]
var hasFirewallRestrictions = privateEndpoint || !empty(kvIpRules)
// Disable public access only when private endpoint is the sole access path with no trusted IP exceptions.
var resolvedPublicNetworkAccess = (privateEndpoint && empty(kvIpRules)) ? 'Disabled' : 'Enabled'
var resolvedNetworkAcls = hasFirewallRestrictions
  ? {
      bypass: requiresAzureServicesBypass ? 'AzureServices' : 'None'
      defaultAction: 'Deny'
      ipRules: kvIpRules
    }
  : requiresAzureServicesBypass
      ? {
          bypass: 'AzureServices'
          defaultAction: 'Allow'
        }
      : null

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: sku
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: enableRbacAuthorization
    enableSoftDelete: enableSoftDelete
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection ? true : null
    enabledForDeployment: enabledForDeployment
    enabledForTemplateDeployment: enabledForTemplateDeployment
    enabledForDiskEncryption: enabledForDiskEncryption
    publicNetworkAccess: resolvedPublicNetworkAccess
    networkAcls: resolvedNetworkAcls
  }
}

var diagTargetNames = filter([
  !empty(diagnosticSettings.?workspaceId ?? '') ? last(split(diagnosticSettings.?workspaceId!, '/')) : ''
  !empty(diagnosticSettings.?storageAccountId ?? '') ? last(split(diagnosticSettings.?storageAccountId!, '/')) : ''
  !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? '')
    ? (!empty(diagnosticSettings.?eventHubName ?? '') ? diagnosticSettings!.eventHubName! : split(diagnosticSettings.?eventHubAuthorizationRuleId!, '/')[8])
    : ''
], t => !empty(t))

var diagnosticSettingName = !empty(diagnosticSettings.?name ?? '')
  ? diagnosticSettings!.name!
  : length(diagTargetNames) > 1
      ? 'diag-${uniqueString(join(diagTargetNames, '-'))}'
      : length(diagTargetNames) == 1
          ? 'diag-${diagTargetNames[0]}'
          : 'diagnostics'

resource diagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettings != null && (!empty(diagnosticSettings.?workspaceId ?? '') || !empty(diagnosticSettings.?storageAccountId ?? '') || !empty(diagnosticSettings.?eventHubAuthorizationRuleId ?? ''))) {
  scope: keyVault
  name: diagnosticSettingName
  properties: {
    workspaceId: diagnosticSettings.?workspaceId
    storageAccountId: diagnosticSettings.?storageAccountId
    eventHubAuthorizationRuleId: diagnosticSettings.?eventHubAuthorizationRuleId
    eventHubName: diagnosticSettings.?eventHubName
    logs: diagnosticSettings.?logCategories ?? [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output resourceId string = keyVault.id
output name string = keyVault.name
output uri string = keyVault.properties.vaultUri

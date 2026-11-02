metadata name = 'Key Vault'
metadata description = 'Deploys a Key Vault in the subscription tenant with caller-controlled protection, authorization, network access and optional diagnostics.'

// Keys, secrets, role assignments and private endpoints are managed separately.

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

@description('Required. Name of the key Vault to deploy.')
param name string
@description('Optional. Azure region for the key Vault; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the key Vault.')
param tags object = {}

@allowed(['standard', 'premium'])
@description('Standard supports software-protected keys. Premium adds HSM-backed key support.')
param sku string = 'premium'

@description('Optional. Use Azure RBAC for vault data-plane authorization; role assignments are managed separately.')
param enableRbacAuthorization bool = true
@description('Optional. Enable soft delete for the vault.')
param enableSoftDelete bool = true
@description('Optional. Number of days deleted vault objects are retained.')
param softDeleteRetentionInDays int = 90
@description('Optional. Enable vault purge protection; false omits the property rather than disabling existing protection.')
param enablePurgeProtection bool = true

@description('Allow ARM to retrieve secrets during deployments. Required if using KV secrets in parameter files.')
param enabledForDeployment bool = false
@description('Optional. Permit ARM template deployments to retrieve secrets from the vault.')
param enabledForTemplateDeployment bool = false
@description('Allow disk encryption operations (Azure Disk Encryption / Disk Encryption Sets) to access the vault.')
param enabledForDiskEncryption bool = false

@allowed(['Enabled', 'Disabled'])
@description('Optional. Public network access mode for this resource; private endpoints are configured separately.')
param publicNetworkAccess string = 'Enabled'

// Match bypass, defaultAction and ipRules to the deployment topology:
// private endpoints, IP allowlists and any required Azure services bypass.
@description('Optional. Vault network ACL object with bypass, defaultAction and ipRules.')
param networkAcls object = {
  bypass: 'None'
  defaultAction: 'Deny'
  ipRules: []
}

// Referenced diagnostic destination resources must already exist.
@description('Optional. Diagnostic destinations and log categories; null or no destination skips diagnostic settings.')
param diagnosticSettings diagnosticSettingsType?

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
    publicNetworkAccess: publicNetworkAccess
    networkAcls: networkAcls
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

@description('Resource ID of the key Vault.')
output resourceId string = keyVault.id
@description('Azure resource name of the key Vault.')
output name string = keyVault.name
@description('HTTPS data-plane URI of the deployed Key Vault.')
output uri string = keyVault.properties.vaultUri

import { diagnosticSettingsType } from '../../types/diagnosticSettings.bicep'

param name string
param location string = resourceGroup().location
param tags object = {}

param publicNetworkAccess string = 'Disabled'

@description('Storage replication type for the vault. GeoRedundant, LocallyRedundant, or ZoneRedundant.')
param storageType string = 'GeoRedundant'

@description('Enable cross-region restore (requires GeoRedundant storage).')
param crossRegionRestoreFlag bool = false

@description('Soft-delete feature state for the vault.')
param softDeleteFeatureState string = 'Enabled'

@description('Enhanced security state for the vault.')
param enhancedSecurityState string = 'Enabled'

param diagnosticSettings diagnosticSettingsType?

resource recoveryServicesVault 'Microsoft.RecoveryServices/vaults@2023-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: publicNetworkAccess
  }
}

resource backupStorageConfig 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2023-04-01' = {
  parent: recoveryServicesVault
  name: 'vaultstorageconfig'
  properties: {
    storageType: storageType
    crossRegionRestoreFlag: crossRegionRestoreFlag
  }
}

resource backupConfig 'Microsoft.RecoveryServices/vaults/backupconfig@2023-04-01' = {
  parent: recoveryServicesVault
  name: 'vaultconfig'
  properties: {
    softDeleteFeatureState: softDeleteFeatureState
    enhancedSecurityState: enhancedSecurityState
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
  scope: recoveryServicesVault
  name: diagnosticSettingName
  properties: {
    workspaceId: diagnosticSettings.?workspaceId
    storageAccountId: diagnosticSettings.?storageAccountId
    eventHubAuthorizationRuleId: diagnosticSettings.?eventHubAuthorizationRuleId
    eventHubName: diagnosticSettings.?eventHubName
    logs: diagnosticSettings.?logCategories ?? [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

output resourceId string = recoveryServicesVault.id
output name string = recoveryServicesVault.name

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

@description('Optional. Customer-managed key URI for vault encryption. Leave empty to use Microsoft-managed encryption.')
param cmkKeyUri string = ''

@description('Optional. User-assigned identity resource ID used by the vault to access the CMK. Mutually exclusive with cmkUseSystemAssignedIdentity.')
param cmkUserAssignedIdentityResourceId string = ''

@description('Optional. When true, the vault uses its system-assigned managed identity to access the CMK key vault. Required when the vault has a private endpoint — Azure does not support user-assigned identity for CMK in that scenario. Mutually exclusive with cmkUserAssignedIdentityResourceId.')
param cmkUseSystemAssignedIdentity bool = false

param diagnosticSettings diagnosticSettingsType?

var cmkEnabled = !empty(cmkKeyUri)

// Validate CMK configuration. Four valid states:
//   1. No CMK, no identity         — platform-managed encryption, no managed identity on vault.
//   2. No CMK, SAI pre-provisioned — Stage A-1 of two-stage SAI CMK deployment. SAI identity is
//                                    established here so that a key vault role assignment can be
//                                    made before CMK is enabled in Stage A-3. cmkKeyUri is empty.
//   3. UAI CMK (no vault PE)       — cmkKeyUri set, cmkUserAssignedIdentityResourceId set, SAI = false.
//   4. SAI CMK (vault PE, A-3)     — cmkKeyUri set, cmkUseSystemAssignedIdentity = true, UAI empty.
// Invalid: key without any identity, both identity types set simultaneously, or malformed URI.
// States 1+2 collapse to: !cmkEnabled && empty(UAI) — valid regardless of cmkUseSystemAssignedIdentity.
// States 3+4: (cmkUseSystemAssignedIdentity == empty(cmkUserAssignedIdentityResourceId)) is true for
// exactly both valid CMK identity states (SAI: true==true; UAI: false==false).
var cmkConfigurationValidated = ((!cmkEnabled && empty(cmkUserAssignedIdentityResourceId)) || (cmkEnabled && contains(cmkKeyUri, '/keys/') && (cmkUseSystemAssignedIdentity == empty(cmkUserAssignedIdentityResourceId))))
  ? true
  : bool('Invalid CMK configuration. Provide cmkKeyUri (including /keys/) with either cmkUserAssignedIdentityResourceId (no vault PE) or cmkUseSystemAssignedIdentity=true (vault PE), but not both identity options simultaneously.')

resource recoveryServicesVault 'Microsoft.RecoveryServices/vaults@2023-04-01' = {
  name: name
  location: location
  tags: tags
  // Identity type is driven by which CMK path is active.
  // cmkUseSystemAssignedIdentity takes priority — it must be true for BOTH stages of the two-stage
  // SAI deployment (Stage A-1: SAI established without CMK; Stage A-3: SAI used to apply CMK).
  // UAI path: only when CMK is active and SAI is not selected.
  identity: cmkUseSystemAssignedIdentity
    ? { type: 'SystemAssigned' }
    : cmkEnabled
        ? {
            type: 'UserAssigned'
            userAssignedIdentities: {
              '${cmkUserAssignedIdentityResourceId}': {}
            }
          }
        : null
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: cmkConfigurationValidated ? publicNetworkAccess : publicNetworkAccess
    encryption: cmkEnabled
      ? {
          keyVaultProperties: {
            keyUri: cmkKeyUri
          }
          // kekIdentity tells Azure Backup which managed identity to use when accessing the key vault.
          // SAI path: useSystemAssignedIdentity=true (required when vault has a private endpoint).
          // UAI path: explicit resource ID (standard configuration, no vault PE).
          kekIdentity: cmkUseSystemAssignedIdentity
            ? { useSystemAssignedIdentity: true }
            : {
                userAssignedIdentity: cmkUserAssignedIdentityResourceId
                useSystemAssignedIdentity: false
              }
        }
      : null
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
// Guard against accessing .identity when the vault was deployed without one.
// When identity is null (platform-managed keys, no SAI/UAI), ARM cannot evaluate
// reference(...).identity.principalId at all — not even with the safe-navigation
// operator — because the property is absent from the API response.
// Use a param-based conditional so ARM short-circuits before touching .identity.
output principalId string = (cmkUseSystemAssignedIdentity || (cmkEnabled && !empty(cmkUserAssignedIdentityResourceId)))
  ? recoveryServicesVault.identity!.principalId!
  : ''

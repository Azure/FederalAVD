// ─────────────────────────────────────────────────────────────────────────────
// FSLogix Azure Files Backup Registration
// Deploys in the Recovery Services Vault's resource group so that ARM child
// resource declarations (protectionContainers, protectedItems) resolve correctly.
// The 'filesharepolicy' backup policy is created upstream in recoveryServices.bicep.
// ─────────────────────────────────────────────────────────────────────────────

param vaultName string
param location string
param fileShares array
param storageAccountResourceIds array
param fileSharePolicyName string = 'filesharepolicy'
param tags object = {}
param hostPoolResourceId string

// ─── Protection Containers ─────────────────────────────────────────────────────
@batchSize(1)
resource protectionContainers 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = [
  for saId in storageAccountResourceIds: {
    name: '${vaultName}/Azure/storagecontainer;Storage;${split(saId, '/')[4]};${last(split(saId, '/'))}'
    properties: {
      friendlyName: last(split(saId, '/'))
      sourceResourceId: saId
      backupManagementType: 'AzureStorage'
      containerType: 'StorageContainer'
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers'] ?? {})
  }
]

// ─── Protected Items ───────────────────────────────────────────────────────────
resource protectedItems 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [
  for (saId, i) in storageAccountResourceIds: {
    name: '${vaultName}/Azure/storagecontainer;Storage;${split(saId, '/')[4]};${last(split(saId, '/'))}/AzureFileShare;${fileShares[0]}'
    location: location
    properties: {
      protectedItemType: 'AzureFileShareProtectedItem'
      policyId: '${resourceGroup().id}/providers/Microsoft.RecoveryServices/vaults/${vaultName}/backupPolicies/${fileSharePolicyName}'
      sourceResourceId: saId
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'] ?? {})
    dependsOn: [protectionContainers]
  }
]

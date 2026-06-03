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

// Flatten (storageAccount × fileShare) into a single array so every share on every
// storage account gets its own protected item, regardless of share count.
var combos = flatten(map(range(0, length(storageAccountResourceIds)), saIdx => map(fileShares, shareName => {
  saId: storageAccountResourceIds[saIdx]
  rgName: split(storageAccountResourceIds[saIdx], '/')[4]
  saName: last(split(storageAccountResourceIds[saIdx], '/'))!
  shareName: shareName
})))

// ─── Protected Items ───────────────────────────────────────────────────────────
resource protectedItems 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [
  for combo in combos: {
    name: '${vaultName}/Azure/storagecontainer;Storage;${combo.rgName};${combo.saName}/AzureFileShare;${combo.shareName}'
    location: location
    properties: {
      protectedItemType: 'AzureFileShareProtectedItem'
      policyId: '${resourceGroup().id}/providers/Microsoft.RecoveryServices/vaults/${vaultName}/backupPolicies/${fileSharePolicyName}'
      sourceResourceId: combo.saId
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'] ?? {})
    dependsOn: [protectionContainers]
  }
]

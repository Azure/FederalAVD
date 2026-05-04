// ─────────────────────────────────────────────────────────────────────────────
// FSLogix Azure Files Backup Registration
// Deploys in the Recovery Services Vault's resource group so that ARM child
// resource declarations (protectionContainers, protectedItems) resolve correctly.
// The 'filesharepolicy' backup policy is created upstream in recoveryServices.bicep.
// ─────────────────────────────────────────────────────────────────────────────

param vaultName string
param location string
param resourceGroupStorage string
param storageAccountNamePrefix string
param storageCount int
param storageIndex int
param fileShares array
param storageAccountResourceIds array
param tags object = {}
param hostPoolResourceId string

// ─── Protection Containers ─────────────────────────────────────────────────────
resource protectionContainers 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = [
  for i in range(0, storageCount): {
    name: '${vaultName}/Azure/storagecontainer;Storage;${resourceGroupStorage};${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
    properties: {
      friendlyName: '${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}'
      sourceResourceId: storageAccountResourceIds[i]
      backupManagementType: 'AzureStorage'
      containerType: 'StorageContainer'
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers'] ?? {})
  }
]

// ─── Protected Items ───────────────────────────────────────────────────────────
resource protectedItems 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [
  for i in range(0, storageCount): {
    name: '${vaultName}/Azure/storagecontainer;Storage;${resourceGroupStorage};${storageAccountNamePrefix}${string(padLeft(i + storageIndex, 2, '0'))}/AzureFileShare;${fileShares[0]}'
    location: location
    properties: {
      protectedItemType: 'AzureFileShareProtectedItem'
      policyId: '${resourceGroup().id}/providers/Microsoft.RecoveryServices/vaults/${vaultName}/backupPolicies/filesharepolicy'
      sourceResourceId: storageAccountResourceIds[i]
    }
    tags: union({ 'cm-resource-parent': hostPoolResourceId }, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'] ?? {})
    dependsOn: [protectionContainers]
  }
]

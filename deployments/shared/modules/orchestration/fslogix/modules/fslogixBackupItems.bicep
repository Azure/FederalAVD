metadata name = 'FSLogix file share backup registration'
metadata description = 'Registers existing Azure Files storage accounts and requested non-Office shares with an existing Recovery Services vault and backup policy.'

// ─────────────────────────────────────────────────────────────────────────────
// FSLogix Azure Files Backup Registration
// Deploys in the Recovery Services Vault's resource group so that ARM child
// resource declarations (protectionContainers, protectedItems) resolve correctly.
// The 'filesharepolicy' backup policy is created upstream in recoveryServices.bicep.
// ─────────────────────────────────────────────────────────────────────────────

@description('Required. Name of the existing Recovery Services vault in the deployment resource group.')
param vaultName string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Shares to protect on every supplied account. office-containers is always excluded.')
param fileShares array
@description('Required. Existing storage account resource IDs; eligible shares are protected on each account.')
param storageAccountResourceIds array
@description('Optional. Name of the existing Azure Files backup policy in the selected Recovery Services vault.')
param fileSharePolicyName string = 'filesharepolicy'
@description('Optional. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object = {}
@description('Optional. Resource ID of the associated AVD host pool, used for resource ownership tags.')
param hostPoolResourceId string = ''

var parentResourceTags = !empty(hostPoolResourceId) ? { 'cm-resource-parent': hostPoolResourceId } : {}
var backupFileShares = filter(fileShares, shareName => toLower(shareName) != 'office-containers')

// ─── Protection Containers ─────────────────────────────────────────────────────
@batchSize(1)
resource protectionContainers 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2024-04-01' = [
  for saId in storageAccountResourceIds: if (!empty(backupFileShares)) {
    name: '${vaultName}/Azure/storagecontainer;Storage;${split(saId, '/')[4]};${last(split(saId, '/'))}'
    properties: {
      friendlyName: last(split(saId, '/'))
      sourceResourceId: saId
      backupManagementType: 'AzureStorage'
      containerType: 'StorageContainer'
    }
    tags: union(parentResourceTags, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers'] ?? {})
  }
]

// Excluding Office shares here also covers callers that supply both container types.
var combos = flatten(map(range(0, length(storageAccountResourceIds)), saIdx => map(backupFileShares, shareName => {
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
    tags: union(parentResourceTags, tags[?'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'] ?? {})
    dependsOn: [protectionContainers]
  }
]

targetScope = 'subscription'

var accounts = [
  '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/storage-tests/providers/Microsoft.Storage/storageAccounts/profiles01'
  '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/storage-tests/providers/Microsoft.Storage/storageAccounts/profiles02'
  '/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/storage-tests/providers/Microsoft.Storage/storageAccounts/profiles03'
]

module unsharded '../../deployments/shared/modules/orchestration/fslogix/modules/fslogixBackupItems.bicep' = {
  scope: resourceGroup('backup-tests')
  params: {
    vaultName: 'unsharded'
    location: 'eastus'
    fileShares: ['profile-containers', 'office-containers']
    storageAccountResourceIds: take(accounts, 1)
  }
}

module sharded '../../deployments/shared/modules/orchestration/fslogix/modules/fslogixBackupItems.bicep' = {
  scope: resourceGroup('backup-tests')
  params: {
    vaultName: 'sharded'
    location: 'eastus'
    fileShares: ['profile-containers', 'office-containers', 'OFFICE-CONTAINERS']
    storageAccountResourceIds: accounts
    fileSharePolicyName: 'profile-snapshots'
  }
}

module officeOnly '../../deployments/shared/modules/orchestration/fslogix/modules/fslogixBackupItems.bicep' = {
  scope: resourceGroup('backup-tests')
  params: {
    vaultName: 'office-only'
    location: 'eastus'
    fileShares: ['office-containers']
    storageAccountResourceIds: accounts
  }
}

module profilesOnly '../../deployments/shared/modules/orchestration/fslogix/modules/fslogixBackupItems.bicep' = {
  scope: resourceGroup('backup-tests')
  params: {
    vaultName: 'profiles-only'
    location: 'eastus'
    fileShares: ['profile-containers']
    storageAccountResourceIds: accounts
  }
}

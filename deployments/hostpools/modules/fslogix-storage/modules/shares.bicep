param fileShares array
param shareSizeInGB int
param StorageAccountName string
param storageSku string

module fileShareModules '../../../../../.common/bicepModules/storage/storageAccounts/fileServices/shares/deploy.bicep' = [
  for i in range(0, length(fileShares)): {
    name: '${StorageAccountName}-${fileShares[i]}'
    params: {
      storageAccountName: StorageAccountName
      name: fileShares[i]
      shareQuota: shareSizeInGB
      accessTier: storageSku == 'Premium' ? 'Premium' : 'TransactionOptimized'
    }
  }
]

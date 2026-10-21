metadata name = 'FSLogix file share orchestration'
metadata description = 'Creates each named SMB share in an existing storage account using a shared quota and a SKU-dependent access tier.'

@description('Required. Array of share name strings to create or register on every supplied storage account.')
param fileShares array
@description('Required. Quota per file share or NetApp volume in GiB.')
param shareSizeInGB int
@description('Required. Name of the existing storage account in the deployment resource group.')
param StorageAccountName string
@description('Required. Storage tier: Standard or Premium for Azure Files, or the NetApp service level for NetApp volumes.')
param storageSku string

module shares '../../../resourceModules/storage/storageAccounts/fileServices/shares/deploy.bicep' = [
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

param storageAccountName string
param name string

@description('Quota in GiB.')
param shareQuota int = 100

@allowed(['TransactionOptimized', 'Hot', 'Cool', 'Premium'])
param accessTier string = 'TransactionOptimized'

@description('Optional. Enabled protocols for the share.')
@allowed(['SMB', 'NFS', ''])
param enabledProtocol string = 'SMB'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: name
  properties: {
    shareQuota: shareQuota
    accessTier: accessTier
    enabledProtocols: !empty(enabledProtocol) ? enabledProtocol : null
  }
}

output resourceId string = fileShare.id
output name string = fileShare.name

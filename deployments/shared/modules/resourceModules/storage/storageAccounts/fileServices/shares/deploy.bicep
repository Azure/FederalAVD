metadata name = 'Azure file share'
metadata description = 'Deploys a share in the default File service of an existing storage account with caller-selected quota, tier and protocol; the account must support those settings.'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string
@description('Required. Name of the azure file share within its parent resource.')
param name string

@description('Quota in GiB.')
param shareQuota int = 100

@allowed(['TransactionOptimized', 'Hot', 'Cool', 'Premium'])
@description('Optional. Azure file share access tier; must be compatible with the parent storage account SKU.')
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

@description('Resource ID of the azure file share.')
output resourceId string = fileShare.id
@description('Azure resource name of the azure file share.')
output name string = fileShare.name

@maxLength(24)
@description('Conditional. The name of the parent Storage Account. Required if the template is used in a standalone deployment.')
param storageAccountName string

@description('Conditional. The name of the parent file service. Required if the template is used in a standalone deployment.')
param fileServicesName string = 'default'

@description('Required. The name of the file share to create.')
param name string

@allowed([
  'Premium'
  'Hot'
  'Cool'
  'TransactionOptimized'
])
@description('Conditional. Access tier for specific share. Required if the Storage Account kind is set to FileStorage (should be set to "Premium"). GpV2 account can choose between TransactionOptimized (default), Hot, and Cool.')
param accessTier string = 'TransactionOptimized'

@description('Optional. The maximum size of the share, in gigabytes. Must be greater than 0, and less than or equal to 5120 (5TB). For Large File Shares, the maximum size is 102400 (100TB).')
param shareQuota int = 5120

@allowed([
  'NFS'
  'SMB'
])
@description('Optional. The authentication protocol that is used for the file share. Can only be specified when creating a share.')
param enabledProtocols string = 'SMB'

@allowed([
  'AllSquash'
  'NoRootSquash'
  'RootSquash'
])
@description('Optional. Permissions for NFS file shares are enforced by the client OS rather than the Azure Files service. Toggling the root squash behavior reduces the rights of the root user for NFS shares.')
param rootSquash string = 'NoRootSquash'

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' existing = {
  name: storageAccountName

  resource fileService 'fileServices@2021-09-01' existing = {
    name: fileServicesName
  }
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2021-09-01' = {
  name: name
  parent: storageAccount::fileService
  properties: {
    accessTier: accessTier
    shareQuota: shareQuota
    rootSquash: enabledProtocols == 'NFS' ? rootSquash : null
    enabledProtocols: enabledProtocols
  }
}

@description('The name of the deployed file share.')
output name string = fileShare.name

@description('The resource ID of the deployed file share.')
output resourceId string = fileShare.id

@description('The resource group of the deployed file share.')
output resourceGroupName string = resourceGroup().name

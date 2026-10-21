metadata name = 'Blob container'
metadata description = 'Deploys a container in the default Blob service of an existing storage account; account-level settings must permit any requested anonymous access.'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string
@description('Required. Name of the blob container within its parent resource.')
param name string

@allowed(['Container', 'Blob', 'None'])
@description('Optional. Anonymous container access level; the storage account must also permit public Blob access.')
param publicAccess string = 'None'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: name
  properties: {
    publicAccess: publicAccess
  }
}

@description('Resource ID of the blob container.')
output resourceId string = container.id
@description('Azure resource name of the blob container.')
output name string = container.name

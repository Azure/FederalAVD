param storageAccountName string
param name string

@allowed(['Container', 'Blob', 'None'])
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

output resourceId string = container.id
output name string = container.name

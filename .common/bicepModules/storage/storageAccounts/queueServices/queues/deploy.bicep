param storageAccountName string
param name string

@description('Optional. Queue metadata as key-value pairs.')
param metadata object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource queue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: name
  properties: {
    metadata: !empty(metadata) ? metadata : null
  }
}

output resourceId string = queue.id
output name string = queue.name

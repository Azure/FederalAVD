metadata name = 'Storage queue'
metadata description = 'Deploys a queue with optional metadata in the default Queue service of an existing storage account in the deployment resource group.'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string
@description('Required. Name of the storage queue within its parent resource.')
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

@description('Resource ID of the storage queue.')
output resourceId string = queue.id
@description('Azure resource name of the storage queue.')
output name string = queue.name

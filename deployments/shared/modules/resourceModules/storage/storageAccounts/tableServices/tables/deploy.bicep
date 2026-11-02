metadata name = 'Storage table'
metadata description = 'Deploys a table in the default Table service of an existing storage account in the deployment resource group.'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string
@description('Required. Name of the storage table within its parent resource.')
param name string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource table 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: name
}

@description('Resource ID of the storage table.')
output resourceId string = table.id
@description('Azure resource name of the storage table.')
output name string = table.name

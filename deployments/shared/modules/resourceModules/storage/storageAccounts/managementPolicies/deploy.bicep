metadata name = 'Blob lifecycle management policy'
metadata description = 'Creates or updates the default lifecycle management policy on an existing storage account using the complete caller-supplied rule array.'

@description('Required. Name of the existing storage account in the deployment resource group.')
param storageAccountName string

@description('Array of lifecycle management policy rules.')
param rules array = []

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource managementPolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: rules
    }
  }
}

@description('Resource ID of the blob lifecycle management policy.')
output resourceId string = managementPolicy.id

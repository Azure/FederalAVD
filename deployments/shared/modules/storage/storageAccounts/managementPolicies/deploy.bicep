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

output resourceId string = managementPolicy.id

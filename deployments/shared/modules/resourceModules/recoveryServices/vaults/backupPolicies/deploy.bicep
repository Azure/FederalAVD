param recoveryServicesVaultName string
param name string

@description('Backup policy properties. The schema varies by workload type (AzureIaasVM, AzureStorage, etc.).')
param properties object

resource vault 'Microsoft.RecoveryServices/vaults@2023-04-01' existing = {
  name: recoveryServicesVaultName
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = {
  parent: vault
  name: name
  properties: properties
}

output resourceId string = backupPolicy.id
output name string = backupPolicy.name

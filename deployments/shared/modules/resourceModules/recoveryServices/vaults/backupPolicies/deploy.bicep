metadata name = 'Recovery Services backup policy'
metadata description = 'Creates or updates a backup policy under an existing Recovery Services vault in the deployment resource group using caller-supplied workload-specific properties.'

@description('Required. Name of the existing Recovery Services vault in the deployment resource group.')
param recoveryServicesVaultName string
@description('Required. Name of the recovery Services backup policy to deploy.')
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

@description('Resource ID of the recovery Services backup policy.')
output resourceId string = backupPolicy.id
@description('Azure resource name of the recovery Services backup policy.')
output name string = backupPolicy.name

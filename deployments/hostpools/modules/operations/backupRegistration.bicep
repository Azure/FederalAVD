targetScope = 'subscription'

// ─────────────────────────────────────────────────────────────────────────────
// Backup Registration Shim
// Subscription-scoped so hostpool.bicep can call it without a deployment-start-
// time scope expression. Inner modules are resource-group-scoped using params.
// Exactly one of registerFSLogix / registerVMs will be true per call.
// ─────────────────────────────────────────────────────────────────────────────

param recoveryServicesVaultResourceId string
param hostPoolResourceId string
param deploymentSuffix string
param tags object = {}

// FSLogix Azure Files registration
param registerFSLogix bool = false
param location string = ''
param fileShares array = []
param storageAccountResourceIds array = []
param fileSharePolicyName string = 'filesharepolicy'

// VM registration (Personal host pool)
param registerVMs bool = false
param vmPolicyName string = 'AvdPolicyVm'
param resourceGroupHosts string = ''
param virtualMachineNames array = []

var vaultSubscriptionId = split(recoveryServicesVaultResourceId, '/')[2]
var vaultRG = split(recoveryServicesVaultResourceId, '/')[4]
var vaultName = last(split(recoveryServicesVaultResourceId, '/'))

module fslogixBackup 'fslogixBackupItems.bicep' = if (registerFSLogix) {
  name: 'FSLogix-BackupRegistration-${deploymentSuffix}'
  scope: resourceGroup(vaultSubscriptionId, vaultRG)
  params: {
    vaultName: vaultName
    location: location
    fileShares: fileShares
    storageAccountResourceIds: storageAccountResourceIds
    fileSharePolicyName: fileSharePolicyName
    tags: tags
    hostPoolResourceId: hostPoolResourceId
  }
}

module vmBackup 'vmBackupItems.bicep' = if (registerVMs) {
  name: 'BackupProtectedItems-VirtualMachines-${deploymentSuffix}'
  scope: resourceGroup(vaultSubscriptionId, vaultRG)
  params: {
    hostPoolResourceId: hostPoolResourceId
    policyName: vmPolicyName
    recoveryServicesVaultName: vaultName
    resourceGroupHosts: resourceGroupHosts
    virtualMachineNames: virtualMachineNames
  }
}

metadata name = 'Session host VM backup registration'
metadata description = 'Protects named existing session-host VMs using an existing Recovery Services vault and VM backup policy in the deployment resource group.'

@description('Required. Name of the existing VM backup policy in the Recovery Services vault.')
param policyName string
@description('Required. Name of the existing Recovery Services vault in the deployment resource group.')
param recoveryServicesVaultName string
@description('Required. Name of the existing resource group containing the session-host VMs in this subscription.')
param resourceGroupHosts string
@description('Required. Array of existing session-host VM name strings in the hosts resource group.')
param virtualMachineNames array
@description('Required. Resource ID of the associated AVD host pool, used for resource ownership tags.')
param hostPoolResourceId string

var v2VmContainer = 'IaasVMContainer;iaasvmcontainerv2;'
var v2Vm = 'vm;iaasvmcontainerv2;'

resource rsv 'Microsoft.recoveryServices/vaults@2023-01-01' existing = {
  name: recoveryServicesVaultName
  resource backupPolicy 'backupPolicies@2024-10-01' existing = {
    name: policyName
  }
}

resource protectedItems_Vm 'Microsoft.recoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-10-01' = [for vmName in virtualMachineNames: {
  name: '${recoveryServicesVaultName}/Azure/${v2VmContainer}${resourceGroupHosts};${vmName}/${v2Vm}${resourceGroupHosts};${vmName}'
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    policyId: rsv::backupPolicy.id
    sourceResourceId: resourceId(resourceGroupHosts, 'Microsoft.Compute/virtualMachines', vmName)
  }
  tags: {
    'cm-resource-parent': hostPoolResourceId
  }
}]

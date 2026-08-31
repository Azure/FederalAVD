param policyName string
param recoveryServicesVaultName string
param resourceGroupHosts string
param virtualMachineNames array
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

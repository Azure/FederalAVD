metadata name = 'Virtual machine backup protection'
metadata description = 'Deploys VM backup protection under a caller-specified Recovery Services vault using an existing VM and backup policy; the caller supplies the protected item name.'

@description('Required. Name of the existing Recovery Services vault in the deployment resource group.')
param recoveryServicesVaultName string
@description('Optional. Azure region for the virtual machine backup protection; defaults to the deployment resource group region.')
param location string = resourceGroup().location

@description('Name of the protected item, formatted as: iaasvmcontainerv2;<rg>;<vmName>/<vmName>')
param name string

@description('Resource ID of the virtual machine to protect.')
param virtualMachineId string

@description('Resource ID of the backup policy to apply.')
param policyId string

// container name: iaasvmcontainerv2;<resourceGroupName>;<vmName>
var vmParts = split(virtualMachineId, '/')
var vmResourceGroup = vmParts[4]
var vmName = vmParts[8]
var containerName = 'iaasvmcontainerv2;${vmResourceGroup};${vmName}'

resource protectedItem 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2023-04-01' = {
  name: '${recoveryServicesVaultName}/Azure/${containerName}/${name}'
  location: location
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    sourceResourceId: virtualMachineId
    policyId: policyId
  }
}

@description('Resource ID of the virtual machine backup protection.')
output resourceId string = protectedItem.id

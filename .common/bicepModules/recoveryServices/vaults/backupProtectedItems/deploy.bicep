param recoveryServicesVaultName string
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

output resourceId string = protectedItem.id

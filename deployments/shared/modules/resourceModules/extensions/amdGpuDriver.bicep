metadata name = 'AMD Windows GPU extension'
metadata description = 'Installs the AMD Windows GPU driver extension on an existing compatible GPU VM in the deployment resource group.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Optional. Azure region for the AMD Windows GPU extension; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the AMD Windows GPU extension.')
param tags object = {}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource amdGpuDriver 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'AmdGpuDriverWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.HpcCompute'
    type: 'AmdGpuDriverWindows'
    typeHandlerVersion: '1.1'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
  }
}

@description('Resource ID of the AMD Windows GPU extension.')
output resourceId string = amdGpuDriver.id
@description('Azure resource name of the AMD Windows GPU extension.')
output name string = amdGpuDriver.name

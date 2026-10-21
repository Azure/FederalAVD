metadata name = 'NVIDIA Windows GPU extension'
metadata description = 'Installs the NVIDIA Windows GPU driver extension on an existing compatible GPU VM in the deployment resource group.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Optional. Azure region for the NVIDIA Windows GPU extension; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the NVIDIA Windows GPU extension.')
param tags object = {}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource nvidiaGpuDriver 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'NvidiaGpuDriverWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.HpcCompute'
    type: 'NvidiaGpuDriverWindows'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
  }
}

@description('Resource ID of the NVIDIA Windows GPU extension.')
output resourceId string = nvidiaGpuDriver.id
@description('Azure resource name of the NVIDIA Windows GPU extension.')
output name string = nvidiaGpuDriver.name

param virtualMachineName string
param location string = resourceGroup().location
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
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
  }
}

output resourceId string = nvidiaGpuDriver.id
output name string = nvidiaGpuDriver.name

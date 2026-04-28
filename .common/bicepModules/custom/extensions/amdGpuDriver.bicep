param virtualMachineName string
param location string = resourceGroup().location
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

output resourceId string = amdGpuDriver.id
output name string = amdGpuDriver.name

param location string
param virtualMachineName string

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: virtualMachineName
}

resource azureMonitorWindowsAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: virtualMachine
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.1'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

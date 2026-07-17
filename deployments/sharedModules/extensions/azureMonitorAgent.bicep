param virtualMachineName string
param location string = resourceGroup().location
param tags object = {}

@description('Enable automatic upgrade of the agent.')
param enableAutomaticUpgrade bool = true

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: enableAutomaticUpgrade
  }
}

output resourceId string = azureMonitorAgent.id
output name string = azureMonitorAgent.name

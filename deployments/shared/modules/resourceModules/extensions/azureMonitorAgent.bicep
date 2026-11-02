metadata name = 'Azure Monitor Windows agent'
metadata description = 'Installs the Azure Monitor Windows agent extension on an existing VM; data collection rules and associations are managed separately.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Optional. Azure region for the azure Monitor Windows agent; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the azure Monitor Windows agent.')
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

@description('Resource ID of the azure Monitor Windows agent.')
output resourceId string = azureMonitorAgent.id
@description('Azure resource name of the azure Monitor Windows agent.')
output name string = azureMonitorAgent.name

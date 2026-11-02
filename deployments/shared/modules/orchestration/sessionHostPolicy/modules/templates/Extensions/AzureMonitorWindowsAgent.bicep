metadata name = 'Azure Monitor Agent remediation template'
metadata description = 'Deploys the Azure Monitor Windows Agent extension on an existing VM in the deployment resource group for Azure Policy remediation.'

@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the existing VM in the deployment resource group.')
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

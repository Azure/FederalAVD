metadata name = 'Virtual machine extension'
metadata description = 'Deploys a caller-selected extension handler on an existing VM in the deployment resource group, with separate public and protected settings.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Required. Name of the virtual machine extension to deploy.')
param name string
@description('Optional. Azure region for the virtual machine extension; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the virtual machine extension.')
param tags object = {}

@description('Extension handler publisher.')
param publisher string

@description('Extension type name.')
param type string

@description('Extension handler version.')
param typeHandlerVersion string

@description('Allow the extension to be automatically upgraded to a newer minor version.')
param autoUpgradeMinorVersion bool = true

@description('Allow the platform to automatically upgrade the extension.')
param enableAutomaticUpgrade bool = false

@description('Public settings for the extension.')
param settings object = {}

@description('Protected (encrypted) settings for the extension.')
@secure()
param protectedSettings object = {}

@description('Suppress failures from the extension.')
param suppressFailures bool = false

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource extension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: name
  location: location
  tags: tags
  properties: {
    publisher: publisher
    type: type
    typeHandlerVersion: typeHandlerVersion
    autoUpgradeMinorVersion: autoUpgradeMinorVersion
    enableAutomaticUpgrade: enableAutomaticUpgrade
    settings: !empty(settings) ? settings : null
    protectedSettings: !empty(protectedSettings) ? protectedSettings : null
    suppressFailures: suppressFailures
  }
}

@description('Resource ID of the virtual machine extension.')
output resourceId string = extension.id
@description('Azure resource name of the virtual machine extension.')
output name string = extension.name

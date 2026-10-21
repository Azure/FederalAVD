metadata name = 'Microsoft Entra Windows login extension'
metadata description = 'Installs the Microsoft Entra Windows login extension on an existing VM; VM identity, supported OS configuration and login role assignments are managed separately.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Optional. Azure region for the microsoft Entra Windows login extension; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the microsoft Entra Windows login extension.')
param tags object = {}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

@description('Resource ID of the microsoft Entra Windows login extension.')
output resourceId string = entraLogin.id
@description('Azure resource name of the microsoft Entra Windows login extension.')
output name string = entraLogin.name

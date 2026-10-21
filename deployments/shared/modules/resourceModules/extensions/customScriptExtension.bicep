metadata name = 'Windows Custom Script extension'
metadata description = 'Runs a caller-supplied command and downloads on an existing Windows VM. Optional output parsing expects successful stdout to contain JSON; private downloads require suitable VM identity access.'

@description('Required. Array of script or supporting-file URIs downloaded by the Windows Custom Script extension.')
param fileUris array
@description('Required. Command executed by the extension after downloading the supplied files; passed in protected settings.')
param commandToExecute string 
@description('Required. Azure region for the windows Custom Script extension; must match the parent resource where required.')
param location string
@description('Optional. Parse successful extension stdout as a JSON object; otherwise return the timestamp and download URI list.')
param output bool = false
@description('Optional. Tags applied to the windows Custom Script extension.')
param tags object = {}
@description('Optional. Execution timestamp in public extension settings; changing it triggers the extension to run again.')
param timeStamp string = utcNow('yyyyMMddhhmmss')
@description('Optional. Client ID of an identity already attached to the VM and authorized to download private artifacts; empty omits identity authentication.')
param userAssignedIdentityClientId string = ''
@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string

var defaultOutputValue =  {
  TimeStamp: timeStamp
  Downloads: fileUris 
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-03-01' existing = {
  name: virtualMachineName
}

resource customScriptExtension 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: virtualMachine
  name: 'CustomScriptExtension'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      timestamp: timeStamp
      fileUris: fileUris
    }
    protectedSettings: !empty(userAssignedIdentityClientId) ? {
      commandToExecute: commandToExecute
      managedIdentity: {
        clientId: userAssignedIdentityClientId
      }
    } : {
      commandToExecute: commandToExecute
    }
  }
}

@description('Parsed stdout JSON object when output is enabled; otherwise an object containing TimeStamp and Downloads.')
output value object = output ? json(filter(customScriptExtension.properties.instanceView.substatuses, item => item.code == 'ComponentStatus/StdOut/succeeded')[0].message) : defaultOutputValue

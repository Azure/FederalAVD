param fileUris array
param commandToExecute string 
param location string
param output bool = false
param tags object = {}
param timeStamp string = utcNow('yyyyMMddhhmmss')
param userAssignedIdentityClientId string = ''
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

output value object = output ? json(filter(customScriptExtension.properties.instanceView.substatuses, item => item.code == 'ComponentStatus/StdOut/succeeded')[0].message) : defaultOutputValue

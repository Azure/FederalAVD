param location string = 'USGovVirginia'
param timeStamp string = utcNow('yyyyMMddhhmmss')
param vmname string = 'vmname'
@description('''Optional. The protected properties to be passed to the CSE extension.
{
  fileUris: [
  'https://.../..../filename.zip'
  'https://.../.../.../filename2.ps1
  ]
  commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command .\\cse_master_script.ps1'
  userAssignedIdentityResourceId: '/subscriptions/.../resourceGroups/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/...'
}
''')
@secure()
param cseExtensionProtectedProperties object = {}

resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' existing = {
  name: vmname
  scope: resourceGroup()
}

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(cseExtensionProtectedProperties.userAssignedIdentityResourceId)) {
  name: last(split(cseExtensionProtectedProperties.userAssignedIdentityResourceId, '/'))
  scope: resourceGroup(
    split(cseExtensionProtectedProperties.userAssignedIdentityResourceId, '/')[2],
    split(cseExtensionProtectedProperties.userAssignedIdentityResourceId, '/')[4]
  )
}

resource CustomScriptExtension 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: vm
  name: 'CustomScriptExtension'
  location: location
  tags: {}
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      timestamp: timeStamp
    }
    protectedSettings: {
      fileUris: cseExtensionProtectedProperties.fileUris
      commandToExecute: cseExtensionProtectedProperties.commandToExecute
      managedIdentity: !empty(cseExtensionProtectedProperties.userAssignedIdentityResourceId)
        ? uai.properties.clientId
        : null
    }
  }
}

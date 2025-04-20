@description('The name of the virtual machine to install the AVD Agent and register as a Session Host.')
param virtualMachineName string

@description('The location of the virtual machine to install the AVD Agent and register as a Session Host.')
param location string = resourceGroup().location

@description('The DSC package name or full Url used by the PowerShell DSC extension to install the AVD Agent and register the virtual machine as a Session Host.')
param avdAgentsDSCPackage string = 'Configuration_1.0.02790.438.zip'

@description('The resource Id of the host pool to register the virtual machine as a Session Host.')
param hostPoolResourceId string

@description('The Session Host is EntraID Joined')
param aadJoin bool = true

@description('The virtual machine is managed by Intune')
param intune bool = true

var sessionHostRegistrationDSCStorageAccount = startsWith(environment().name, 'USN')
  ? 'wvdexportalcontainer'
  : 'wvdportalstorageblob'
var sessionHostRegistrationDSCUrl = startsWith(avdAgentsDSCPackage, 'https://')
  ? avdAgentsDSCPackage
  : 'https://${sessionHostRegistrationDSCStorageAccount}.blob.${environment().suffixes.storage}/galleryartifacts/${avdAgentsDSCPackage}'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = {
  name: last(split(hostPoolResourceId, '/'))
  scope: resourceGroup(split(hostPoolResourceId, '/')[2], split(hostPoolResourceId, '/')[4])
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-03-01' existing = {
  name: virtualMachineName
}

resource extension_DSC_installAvdAgents 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: virtualMachine
  name: 'AVDAgentInstallandConfig'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: sessionHostRegistrationDSCUrl
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: last(split(hostPoolResourceId, '/'))
        registrationInfoTokenCredential: {
          UserName: 'PLACEHOLDER_DO_NOT_USE'
          Password: 'PrivateSettingsRef:RegistrationInfoToken'
        }
        aadJoin: aadJoin
        UseAgentDownloadEndpoint: false
        mdmId: intune ? '0000000a-0000-0000-c000-000000000000' : ''
      }
    }
    protectedSettings: {
      Items: {
        RegistrationInfoToken: hostPool.listRegistrationTokens().value[0].token
      }
    }
  }
}

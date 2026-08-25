param virtualMachineName string
param location string = resourceGroup().location
param tags object = {}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource guestAttestation 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'GuestAttestation'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: ''
          maaTenantName: 'GuestAttestation'
        }
        AscSettings: {
          ascReportingEndpoint: ''
          ascReportingFrequency: ''
        }
        useCustomToken: 'false'
        disableAlerts: 'false'
      }
    }
  }
}

output resourceId string = guestAttestation.id
output name string = guestAttestation.name

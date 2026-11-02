metadata name = 'Windows guest attestation extension'
metadata description = 'Installs the Windows guest attestation extension on an existing compatible VM using the built-in attestation settings.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Optional. Azure region for the windows guest attestation extension; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the windows guest attestation extension.')
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

@description('Resource ID of the windows guest attestation extension.')
output resourceId string = guestAttestation.id
@description('Azure resource name of the windows guest attestation extension.')
output name string = guestAttestation.name

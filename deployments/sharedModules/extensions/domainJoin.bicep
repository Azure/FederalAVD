param virtualMachineName string
param location string = resourceGroup().location
param tags object = {}

@description('Domain to join.')
param domainName string

@description('FQDN or UPN of the domain join account.')
param domainJoinUserPrincipalName string

@secure()
@description('Password of the domain join account.')
param domainJoinUserPassword string

@description('Organizational Unit path for the computer object.')
param ouPath string = ''

@description('Restart after joining the domain.')
param restartNeeded bool = true

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: virtualMachineName
}

resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'DomainJoin'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      OUPath: ouPath
      User: domainJoinUserPrincipalName
      Restart: string(restartNeeded)
      Options: '3'
    }
    protectedSettings: {
      Password: domainJoinUserPassword
    }
  }
}

output resourceId string = domainJoin.id
output name string = domainJoin.name

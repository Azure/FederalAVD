metadata name = 'Active Directory domain join extension'
metadata description = 'Joins an existing Windows VM to Active Directory using caller-supplied credentials and an optional OU. Domain connectivity and join permissions are caller prerequisites.'

@description('Required. Name of the existing virtual machine in the deployment resource group.')
param virtualMachineName string
@description('Optional. Azure region for the active Directory domain join extension; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the active Directory domain join extension.')
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

@description('Resource ID of the active Directory domain join extension.')
output resourceId string = domainJoin.id
@description('Azure resource name of the active Directory domain join extension.')
output name string = domainJoin.name

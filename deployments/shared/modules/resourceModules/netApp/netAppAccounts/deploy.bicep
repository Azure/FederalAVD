metadata name = 'Azure NetApp Files account'
metadata description = 'Deploys an Azure NetApp Files account with optional Active Directory settings for SMB; capacity pools, volumes and required directory connectivity are managed separately.'

@description('Required. Name of the azure NetApp Files account within its parent resource.')
param name string
@description('Optional. Azure region for the azure NetApp Files account; defaults to the deployment resource group region.')
param location string = resourceGroup().location
@description('Optional. Tags applied to the azure NetApp Files account.')
param tags object = {}

@description('Optional. Active Directory settings required for SMB volume access.')
param activeDirectory object = {}

resource netAppAccount 'Microsoft.NetApp/netAppAccounts@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    activeDirectories: !empty(activeDirectory) ? [activeDirectory] : []
  }
}

@description('Resource ID of the azure NetApp Files account.')
output resourceId string = netAppAccount.id
@description('Azure resource name of the azure NetApp Files account.')
output name string = netAppAccount.name

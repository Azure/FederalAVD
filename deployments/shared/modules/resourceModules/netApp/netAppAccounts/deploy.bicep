param name string
param location string = resourceGroup().location
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

output resourceId string = netAppAccount.id
output name string = netAppAccount.name

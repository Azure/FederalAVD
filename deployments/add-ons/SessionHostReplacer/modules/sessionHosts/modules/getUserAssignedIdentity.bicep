targetScope = 'subscription'

param userAssignedIdentityResourceId string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: last(split(userAssignedIdentityResourceId, '/'))
  scope: resourceGroup(split(userAssignedIdentityResourceId, '/')[2], split(userAssignedIdentityResourceId, '/')[4])
}

output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId

param location string
param name string
param identity object = {}
param hardwareProfile object
param storageProfile object
@secure()
param osProfile object
param networkProfile object
param logsUserAssignedIdentityResourceId string
param scriptsUserAssignedIdentityResourceId string

var identityType = contains(identity, 'type')
  ? contains(toLower(identity.type), 'userassigned')
    ? identity.type
    : !empty(logsUserAssignedIdentityResourceId) || !empty(scriptsUserAssignedIdentityResourceId)
      ? 'SystemAssigned, UserAssigned'
      : 'SystemAssigned'
  : !empty(logsUserAssignedIdentityResourceId) || !empty(scriptsUserAssignedIdentityResourceId)
    ? 'UserAssigned'
    : ''

var logsIdentity = empty(logsUserAssignedIdentityResourceId)
  ? {}
  : { '${logsUserAssignedIdentityResourceId}': {} }
var scriptsIdentity = empty(scriptsUserAssignedIdentityResourceId)
  ? {}
  : { '${scriptsUserAssignedIdentityResourceId}': {} }

var userAssignedIdentities = union(identity.?userAssignedIdentities ?? {}, logsIdentity, scriptsIdentity)

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  location: location
  name: name
  identity: empty(identityType) ? null : {
    type: identityType
    userAssignedIdentities: userAssignedIdentities
  }
  properties: {
    hardwareProfile: hardwareProfile
    storageProfile: storageProfile
    osProfile: osProfile
    networkProfile: networkProfile
  }
}

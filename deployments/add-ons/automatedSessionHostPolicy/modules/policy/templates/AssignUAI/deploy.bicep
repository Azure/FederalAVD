param userAssignedIdentityResourceId string
param vmName string
param location string

module getVm 'getVm.bicep' = {
  name: 'get-${vmName}'
  params: {
    vmname: vmName
  }
}

var identityType = (contains(getVm.outputs.identityType, 'SystemAssigned') ? 'SystemAssigned, UserAssigned' : 'UserAssigned')
var userAssignedIdentities = union(getVm.outputs.userAssignedIdentities, {
  '${userAssignedIdentityResourceId}': {}
})

module updateVm 'updateVM.bicep' = {
  name: 'update-${vmName}'
  params: {
    identityType: identityType
    userAssignedIdentities: userAssignedIdentities
    vmName: vmName
    location: location
  }
}

metadata name = 'Artifact identity attachment orchestration'
metadata description = 'Reads an existing VM identity map, unions in the artifact identity, and updates the VM with system-assigned and user-assigned identity types before customization remediation.'

@description('Required. Resource ID of the existing artifact identity attached to the VM and authorized to read the private artifacts.')
param userAssignedIdentityResourceId string
@description('Required. Name of the existing VM in the deployment resource group.')
param vmName string
@description('Required. Azure region for the resources deployed by this module.')
param location string

module getVm 'getVm.bicep' = {
  name: 'get-${vmName}'
  params: {
    vmname: vmName
  }
}

var identityType = 'SystemAssigned, UserAssigned'
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

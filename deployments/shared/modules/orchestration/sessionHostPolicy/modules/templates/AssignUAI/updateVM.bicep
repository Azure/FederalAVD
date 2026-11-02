metadata name = 'VM identity remediation update'
metadata description = 'Updates the identity type and user-assigned identity map of a named VM in the deployment resource group using the supplied location and complete identity map.'

@description('Required. Name of the existing VM in the deployment resource group.')
param vmName string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Complete VM identity type value to apply, such as SystemAssigned, UserAssigned, or their combined value.')
param identityType string
@description('Required. Complete VM user-assigned identity map keyed by identity resource ID, with an empty object per entry.')
param userAssignedIdentities object

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: {
    type: identityType
    userAssignedIdentities: userAssignedIdentities
  }
}

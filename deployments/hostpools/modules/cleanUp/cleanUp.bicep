targetScope = 'subscription' 

param location string
param resourceGroupHosts string
param resourceGroupDeployment string
param deploymentSuffix string
param userAssignedIdentityClientId string
param deploymentVirtualMachineName string
param roleAssignmentIds array
param virtualMachineNames array

module removeRunCommands 'modules/removeRunCommands.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  name: 'Remove-RunCommands-${deploymentSuffix}'
  params: {
    location: location
    deploymentVmName: deploymentVirtualMachineName
    deploymentSuffix: deploymentSuffix
    userAssignedIdentityClientId: userAssignedIdentityClientId
    virtualMachineNames: virtualMachineNames
    virtualMachinesResourceGroup: resourceGroupHosts
  }
}

// Remove role assignments for the user Assigned Identity for resource groups other than the deployment resource group to allow the deletion of the resource group.
module removeRoleAssignments 'modules/removeRoleAssignments.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  name: 'Remove-RoleAssignments-${deploymentSuffix}'
  params: {
    location: location
    managementVmName: deploymentVirtualMachineName
    roleAssignmentIds: roleAssignmentIds
    deploymentSuffix: deploymentSuffix
    userAssignedIdentityClientId: userAssignedIdentityClientId
  }
  dependsOn: [
    removeRunCommands
  ]
}

module removeDeploymentResourceGroup 'modules/removeDeploymentResourceGroup.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  name: 'Delete-DeploymentResourceGroup-${deploymentSuffix}'
  params: {
    location: location
    deploymentVmName: deploymentVirtualMachineName
    deploymentSuffix: deploymentSuffix
    userAssignedIdentityClientId: userAssignedIdentityClientId
  }
  dependsOn: [
    removeRunCommands
    removeRoleAssignments
  ]
}

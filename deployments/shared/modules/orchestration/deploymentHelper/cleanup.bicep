metadata name = 'Deployment helper cleanup orchestration'
metadata description = 'Runs cleanup on an existing helper VM for session-host Run Commands, supplied role assignments, and the deployment resource group.'

targetScope = 'subscription'

@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Name of the existing resource group containing the session-host VMs in this subscription.')
param resourceGroupHosts string
@description('Required. Name of the existing resource group containing the deployment helper VM.')
param resourceGroupDeployment string
@description('Required. Client ID of the identity attached to the VM and authorized for the requested operations.')
param userAssignedIdentityClientId string
@description('Required. Name of the existing deployment helper VM used to execute storage or cleanup Run Commands.')
param deploymentVirtualMachineName string
@description('Required. Array of role assignment resource ID strings to remove in the supplied order.')
param roleAssignmentIds array
@description('Required. Array of existing session-host VM name strings in the hosts resource group.')
param virtualMachineNames array
@description('Optional. Whether to remove session-host Run Commands before removing role assignments and the deployment resource group.')
param removeHostRunCommands bool = true

// Remove host commands before revoking the helper permissions. The final group deletion is
// asynchronous because that group contains the helper VM executing the cleanup.
module removeRunCommands '../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (removeHostRunCommands) {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RunCommands'
    location: location
    script: loadTextContent('../../../scripts/Remove-RunCommands.ps1')
    timeoutInSeconds: 3600
    treatFailureAsDeploymentFailure: true
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'SubscriptionId', value: subscription().subscriptionId }
      { name: 'UserAssignedIdentityClientId', value: userAssignedIdentityClientId }
      { name: 'VirtualMachineNames', value: string(virtualMachineNames) }
      { name: 'virtualMachinesResourceGroup', value: resourceGroupHosts }
    ]
  }
}

module removeRoleAssignments '../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RoleAssignments'
    location: location
    script: loadTextContent('../../../scripts/Remove-RoleAssignments.ps1')
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: true
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'RoleAssignmentIds', value: string(roleAssignmentIds) }
      { name: 'UserAssignedIdentityClientId', value: userAssignedIdentityClientId }
    ]
  }
  dependsOn: [removeRunCommands]
}

module removeDeploymentResourceGroup '../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Delete-DeploymentResourceGroup'
    location: location
    script: loadTextContent('../../../scripts/Remove-ResourceGroup.ps1')
    asyncExecution: true
    parameters: [
      {
        name: 'ResourceGroupResourceId'
        value: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroupDeployment}'
      }
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'UserAssignedIdentityClientId', value: userAssignedIdentityClientId }
    ]
  }
  dependsOn: [removeRoleAssignments]
}

targetScope = 'subscription'

param location string
param resourceGroupHosts string
param resourceGroupDeployment string
param deploymentSuffix string
param userAssignedIdentityClientId string
param deploymentVirtualMachineName string
param roleAssignmentIds array
param virtualMachineNames array
param removeHostRunCommands bool = true

module removeRunCommands '../../resourceModules/compute/virtualMachines/runCommands/deploy.bicep' = if (removeHostRunCommands) {
  name: 'Remove-RunCommands-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RunCommands-${deploymentSuffix}'
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
  name: 'Remove-RoleAssignments-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RoleAssignments-${deploymentSuffix}'
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
  name: 'Delete-DeploymentResourceGroup-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Delete-DeploymentResourceGroup-${deploymentSuffix}'
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

targetScope = 'subscription'

param location string
param resourceGroupHosts string
param resourceGroupDeployment string
param deploymentSuffix string
param userAssignedIdentityClientId string
param deploymentVirtualMachineName string
param roleAssignmentIds array
param virtualMachineNames array

// Remove run commands left on session host VMs from earlier deployment stages
module removeRunCommands '../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Remove-RunCommands-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RunCommands-${deploymentSuffix}'
    location: location
    script: loadTextContent('../../../../.common/scripts/Remove-RunCommands.ps1')
    asyncExecution: true
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'SubscriptionId', value: subscription().subscriptionId }
      { name: 'UserAssignedIdentityClientId', value: userAssignedIdentityClientId }
      { name: 'VirtualMachineNames', value: string(virtualMachineNames) }
      { name: 'virtualMachinesResourceGroup', value: resourceGroupHosts }
    ]
  }
}

// Remove role assignments on other resource groups so the deployment resource group can be deleted
module removeRoleAssignments '../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Remove-RoleAssignments-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RoleAssignments-${deploymentSuffix}'
    location: location
    script: loadTextContent('../../../../.common/scripts/Remove-RoleAssignments.ps1')
    asyncExecution: true
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'RoleAssignmentIds', value: string(roleAssignmentIds) }
      { name: 'UserAssignedIdentityClientId', value: userAssignedIdentityClientId }
    ]
  }
  dependsOn: [removeRunCommands]
}

// Self-delete the deployment resource group (VM deletes itself and the RG via script)
module removeDeploymentResourceGroup '../../../../.common/bicepModules/compute/virtualMachines/runCommands/deploy.bicep' = {
  name: 'Delete-DeploymentResourceGroup-${deploymentSuffix}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Delete-DeploymentResourceGroup-${deploymentSuffix}'
    location: location
    script: loadTextContent('../../../../.common/scripts/Remove-ResourceGroup.ps1')
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
  dependsOn: [removeRunCommands, removeRoleAssignments]
}

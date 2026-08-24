targetScope = 'subscription'

param location string
param deploymentResourceGroupName string
param deploymentSuffix string
param deploymentUserAssignedIdentityClientId string
param deploymentVirtualMachineName string
param externalRoleAssignmentResourceIds array

module removeRoleAssignments '../../../shared/modules/compute/virtualMachines/runCommands/deploy.bicep' = {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Remove-RoleAssignments-${deploymentSuffix}'
    location: location
    script: loadTextContent('../../../shared/scripts/Remove-RoleAssignments.ps1')
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: true
    parameters: [
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'RoleAssignmentIds', value: string(externalRoleAssignmentResourceIds) }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
    ]
  }
}

module removeDeploymentResourceGroup '../../../shared/modules/compute/virtualMachines/runCommands/deploy.bicep' = {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    virtualMachineName: deploymentVirtualMachineName
    name: 'Delete-DeploymentResourceGroup-${deploymentSuffix}'
    location: location
    script: loadTextContent('../../../shared/scripts/Remove-ResourceGroup.ps1')
    asyncExecution: true
    parameters: [
      {
        name: 'ResourceGroupResourceId'
        value: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${deploymentResourceGroupName}'
      }
      { name: 'ResourceManagerUri', value: environment().resourceManager }
      { name: 'UserAssignedIdentityClientId', value: deploymentUserAssignedIdentityClientId }
    ]
  }
  dependsOn: [removeRoleAssignments]
}

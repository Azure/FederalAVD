targetScope = 'subscription'

@description('Required. Automated host-pool name.')
param hostPoolName string

@description('Required. Resource group containing the automated host pool.')
param controlPlaneResourceGroupName string

@description('Required. Resource group receiving automated session hosts.')
param sessionHostResourceGroupName string

@description('Required. Resource ID of the session-host subnet.')
param subnetResourceId string

@description('Optional. Resource ID of the network security group attached to session-host NICs.')
param networkSecurityGroupResourceId string = ''

@description('Optional. Resource ID of the selected Compute Gallery image version.')
param customImageResourceId string = ''

@description('Required. Resource ID of the credential Key Vault.')
param credentialsKeyVaultResourceId string

@description('Required. Principal ID of the automated host-pool managed identity.')
param principalId string

var desktopVirtualizationVirtualMachineContributorRoleId = 'a959dbd1-f747-45e3-8ba6-dd80f235f97c'
var virtualMachineContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var networkSecurityGroupSubscriptionDiffers = !empty(networkSecurityGroupResourceId) && toLower(split(networkSecurityGroupResourceId, '/')[2]) != toLower(split(subnetResourceId, '/')[2])
var networkSecurityGroupResourceGroupDiffers = !empty(networkSecurityGroupResourceId) && toLower(split(networkSecurityGroupResourceId, '/')[4]) != toLower(split(subnetResourceId, '/')[4])
var deployNetworkSecurityGroupRoles = networkSecurityGroupSubscriptionDiffers || networkSecurityGroupResourceGroupDiffers

module sessionHostResourceGroupRole '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to create and manage automated session hosts.'
  }
}

module networkResourceGroupRole '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(split(subnetResourceId, '/')[2], split(subnetResourceId, '/')[4])
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to attach automated session hosts to the selected network.'
  }
}

module networkSecurityGroupDesktopVirtualizationRole '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (deployNetworkSecurityGroupRoles) {
  scope: resourceGroup(split(networkSecurityGroupResourceId, '/')[2], split(networkSecurityGroupResourceId, '/')[4])
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to attach the selected network security group to automated session hosts.'
  }
}

module networkSecurityGroupVirtualMachineRole '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (deployNetworkSecurityGroupRoles) {
  scope: resourceGroup(split(networkSecurityGroupResourceId, '/')[2], split(networkSecurityGroupResourceId, '/')[4])
  params: {
    roleDefinitionId: virtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to use a network security group outside the session-host subnet resource group.'
  }
}

module imageResourceGroupRole '../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (!empty(customImageResourceId)) {
  scope: resourceGroup(split(customImageResourceId, '/')[2], split(customImageResourceId, '/')[4])
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to read the selected Compute Gallery image.'
  }
}

module credentialVaultRole '../../shared/modules/keyVault/vaults/roleAssignment.bicep' = {
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
  params: {
    keyVaultName: last(split(credentialsKeyVaultResourceId, '/'))
    assignments: [
      {
        roleDefinitionId: keyVaultSecretsUserRoleId
        principalId: principalId
        principalType: 'ServicePrincipal'
        description: 'Allows Azure Virtual Desktop to retrieve automated session-host credentials.'
      }
    ]
  }
}

module hostPoolResourceRole 'hostPoolRoleAssignment.bicep' = {
  scope: resourceGroup(controlPlaneResourceGroupName)
  params: {
    hostPoolName: hostPoolName
    principalId: principalId
  }
}

output roleAssignmentResourceIds string[] = concat(
  [
    sessionHostResourceGroupRole.outputs.resourceId
    networkResourceGroupRole.outputs.resourceId
    hostPoolResourceRole.outputs.resourceId
  ],
  credentialVaultRole.outputs.resourceIds,
  !empty(customImageResourceId) ? [imageResourceGroupRole!.outputs.resourceId] : [],
  deployNetworkSecurityGroupRoles
    ? [
        networkSecurityGroupDesktopVirtualizationRole!.outputs.resourceId
        networkSecurityGroupVirtualMachineRole!.outputs.resourceId
      ]
    : []
)

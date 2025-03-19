targetScope = 'subscription'

param appGroupSecurityGroups array
param avdObjectId string
param confidentialVMOSDiskEncryption bool
param deployScalingPlan bool
param diskSku string
@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param deploymentVmSize string
param encryptionAtHost bool
param fslogix bool
param hostPoolName string
param identitySolution string
param keyManagementDisks string
param locationVirtualMachines string
param ouPath string
param resourceGroupControlPlane string
param resourceGroupDeployment string
param resourceGroupHosts string
param resourceGroupStorage string
param roleDefinitions object
param startVmOnConnect bool
param tags object
param timeStamp string
param userAssignedIdentityNameConv string
param virtualMachineName string
param virtualMachineNICName string
param virtualMachineDiskName string
@secure()
param virtualMachineAdminPassword string
@secure()
param virtualMachineAdminUserName string
param virtualMachineSubnetResourceId string

var deploymentUserAssignedIdentityName = replace(userAssignedIdentityNameConv, 'TOKEN', 'avd-deployment')

var roleAssignmentsControlPlane = [
  {
    roleDefinitionId: roleDefinitions.DesktopVirtualizationApplicationGroupContributor // (Purpose: updates the friendly name for the desktop)
    depName: 'ControlPlane-DVAppGroupCont'
    resourceGroup: resourceGroupControlPlane
    subscription: subscription().subscriptionId
  }
  {
    roleDefinitionId: roleDefinitions.DesktopVirtualizationSessionHostOperator // (Purpose: sets drain mode on the AVD session hosts)
    depName: 'ControlPlane-DVSessionHostOp'
    resourceGroup: resourceGroupControlPlane
    subscription: subscription().subscriptionId
  }
  {
    roleDefinitionId: roleDefinitions.DesktopVirtualizationWorkspaceContributor // (Purpose: update the app group references on an existing feed workspace)
    depName: 'ControlPlane-DVWorkspaceCont'
    resourceGroup: resourceGroupControlPlane
    subscription: subscription().subscriptionId
  }
  {
    roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the control plane role assignments for the deployment identity. This role Assignment must remain last in the list.)
    depName: 'ControlPlane-RBACAdmin'
    resourceGroup: resourceGroupControlPlane
    subscription: subscription().subscriptionId
  }
]

var roleAssignmentsHosts = union(
  [
    {
      roleDefinitionId: roleDefinitions.VirtualMachineContributor // (Purpose: remove the run commands from the host VMs)
      depName: 'Hosts-VMCont'
      resourceGroup: resourceGroupHosts
      subscription: subscription().subscriptionId
    }
    {
      roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the hosts resource group role assignment for the deployment identity. This role Assignment must remain last in the list.)
      depName: 'Hosts-RBACAdmin'
      resourceGroup: resourceGroupHosts
      subscription: subscription().subscriptionId
    }
  ],
  confidentialVMOSDiskEncryption && contains(keyManagementDisks, 'CustomerManaged')
    ? [
        {
          roleDefinitionId: roleDefinitions.KeyVaultCryptoOfficer // (Purpose: Retrieve the customer managed keys from the key vault for idempotent deployment)
          depName: 'Hosts-KVCryptoOff'
          resourceGroup: resourceGroupHosts
          subscription: subscription().subscriptionId
        }
      ]
    : []
)

var roleAssignmentsDeployment = [
  {
    roleDefinitionId: roleDefinitions.Contributor // (Purpose: remove the deployment resource group during cleanup as there won't be any resources within.)
    depName: 'Deployment-Cont'
    resourceGroup: resourceGroupDeployment
    subscription: subscription().subscriptionId
  }
]

var roleAssignmentStorage = fslogix && contains(identitySolution, 'DomainServices')
  ? [
      {
        roleDefinitionId: roleDefinitions.StorageAccountContributor // (Purpose: domain join storage account & set NTFS permissions on the file share)
        depName: 'Storage-StorageAcctCont'
        resourceGroup: resourceGroupStorage
        subscription: subscription().subscriptionId
      }
      {
        roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the control plane role assignments for the deployment identity. This role assignment must remain last in the list.)
        depName: 'Storage-RBACAdmin'
        resourceGroup: resourceGroupStorage
        subscription: subscription().subscriptionId
      }
    ]
  : []

  var roleAssignments = union(
  roleAssignmentsControlPlane,
  roleAssignmentsDeployment,
  roleAssignmentsHosts,
  roleAssignmentStorage
)

module deploymentUserAssignedIdentity '../../../sharedModules/resources/managed-identity/user-assigned-identity/main.bicep' = {
  name: 'UserAssignedIdentity_Deployment_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    location: locationVirtualMachines
    name: deploymentUserAssignedIdentityName
    tags: union({'cm-resource-parent': '${subscription().id}}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'}, tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {})
  }
}

// Role Assignment required for Start VM On Connect
module roleAssignment_PowerOnContributor '../../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = if (!deployScalingPlan && startVmOnConnect) {
  name: 'RA-PowerOnContributor_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    principalId: avdObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitions.DesktopVirtualizationPowerOnContributor
  }
}

// Role Assignment required for Scaling Plans
module roleAssignment_PowerOnOffContributor '../../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = if (deployScalingPlan) {
  name: 'RA-Hosts-PowerOnOffContributor_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    principalId: avdObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitions.DesktopVirtualizationPowerOnOffContributor
  }
}

// Required for EntraID login
module roleAssignment_VirtualMachineUserLogin '../../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = [for i in range(0, length(appGroupSecurityGroups)): if (!contains(identitySolution, 'DomainServices')) {
  name: 'RA-Hosts-VMLoginUser-${i}_${timeStamp}'
  scope: resourceGroup(resourceGroupHosts)
  params: {
    principalId: appGroupSecurityGroups[i]
    principalType: 'Group'
    roleDefinitionId: roleDefinitions.VirtualMachineUserLogin
  }
}]

module roleAssignments_deployment '../../../sharedModules/resources/authorization/role-assignment/resource-group/main.bicep' = [
  for i in range(0, length(roleAssignments)): {
    scope: resourceGroup(roleAssignments[i].subscription, roleAssignments[i].resourceGroup)
    name: 'RA-${roleAssignments[i].depName}-${timeStamp}'
    params: {
      principalId: deploymentUserAssignedIdentity.outputs.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleAssignments[i].roleDefinitionId
    }
  }
]

// Deployment VM
module virtualMachine 'modules/virtualMachine.bicep' = {
  name: 'VirtualMachine_Deployment_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    identitySolution: identitySolution
    diskName: virtualMachineDiskName
    diskSku: diskSku
    domainJoinUserPassword: domainJoinUserPassword
    domainJoinUserPrincipalName: domainJoinUserPrincipalName
    domainName: domainName
    encryptionAtHost: encryptionAtHost
    location: locationVirtualMachines
    networkInterfaceName: virtualMachineNICName
    ouPath: ouPath
    subnetResourceId: virtualMachineSubnetResourceId
    tagsNetworkInterfaces: union({'cm-resource-parent': '${subscription().id}}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'}, tags[?'Microsoft.Network/networkInterfaces'] ?? {})
    tagsVirtualMachines: union({'cm-resource-parent': '${subscription().id}}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'}, tags[?'Microsoft.Compute/virtualMachines'] ?? {})
    timeStamp: timeStamp
    userAssignedIdentitiesResourceIds: {
      '${deploymentUserAssignedIdentity.outputs.resourceId}': {}
    }
    virtualMachineName: virtualMachineName
    virtualMachineAdminPassword: virtualMachineAdminPassword
    virtualMachineAdminUserName: virtualMachineAdminUserName
    vmSize: deploymentVmSize
  }
}

output deploymentUserAssignedIdentityClientId string = deploymentUserAssignedIdentity.outputs.clientId
output deploymentUserAssignedIdentityResourceId string = deploymentUserAssignedIdentity.outputs.resourceId
output deploymentUserAssignedIdentityRoleAssignmentIds array = [
  for i in range(0, length(roleAssignments)): roleAssignments_deployment[i].outputs.resourceId
]
output virtualMachineName string = virtualMachine.outputs.Name

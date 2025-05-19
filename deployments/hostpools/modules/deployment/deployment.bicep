targetScope = 'subscription'

param confidentialVMOSDiskEncryption bool
param deploymentType string
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
param resourceGroupManagement string
param resourceGroupStorage string
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

var roleDefinitions = {
  Contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  DesktopVirtualizationApplicationGroupContributor: '86240b0e-9422-4c43-887b-b61143f32ba8'
  DesktopVirtualizationSessionHostOperator: '2ad6aaab-ead9-4eaa-8ac5-da422f562408'
  KeyVaultCryptoOfficer: '14b46e9e-c2b7-41b4-b07b-48a6ebf60603'
  RoleBasedAccessControlAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  StorageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  VirtualMachineContributor: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
}

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
    roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the control plane role assignments for the deployment identity. This role Assignment must remain last in the list.)
    depName: 'ControlPlane-RBACAdmin'
    resourceGroup: resourceGroupControlPlane
    subscription: subscription().subscriptionId
  }
]

var roleAssignmentsDeployment = [
  {
    roleDefinitionId: roleDefinitions.Contributor // (Purpose: remove the deployment resource group during cleanup as there won't be any resources within.)
    depName: 'Deployment-Cont'
    resourceGroup: resourceGroupDeployment
    subscription: subscription().subscriptionId
  }
]

var roleAssignmentsHosts = [
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
]

var roleAssignmentsManagement = deploymentType == 'Complete' && confidentialVMOSDiskEncryption && keyManagementDisks == 'CustomerManagedHSM'
  ? [
      {
        roleDefinitionId: roleDefinitions.KeyVaultCryptoOfficer // (Purpose: Retrieve the customer managed keys from the key vault for idempotent deployment)
        depName: 'Management-KVCryptoOff'
        resourceGroup: resourceGroupManagement
        subscription: subscription().subscriptionId
      }
    ]
  : []

var roleAssignmentsStorage = deploymentType == 'Complete' && fslogix && contains(identitySolution, 'DomainServices')
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
  roleAssignmentsManagement,
  roleAssignmentsStorage
)

module deploymentUserAssignedIdentity '../../../sharedModules/resources/managed-identity/user-assigned-identity/main.bicep' = {
  name: 'UserAssignedIdentity_Deployment_${timeStamp}'
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    location: locationVirtualMachines
    name: deploymentUserAssignedIdentityName
    tags: union(
      {
        'cm-resource-parent': '${subscription().id}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'
      },
      tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
    )
  }
}

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
    tagsNetworkInterfaces: union(
      {
        'cm-resource-parent': '${subscription().id}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'
      },
      tags[?'Microsoft.Network/networkInterfaces'] ?? {}
    )
    tagsVirtualMachines: union(
      {
        'cm-resource-parent': '${subscription().id}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'
      },
      tags[?'Microsoft.Compute/virtualMachines'] ?? {}
    )
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

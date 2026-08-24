targetScope = 'subscription'

@secure()
param domainJoinUserPassword string
@secure()
param domainJoinUserPrincipalName string
param domainName string
param domainJoinDeploymentVirtualMachine bool
param identitySolution string
param appUpdateUserAssignedIdentityResourceId string
param location string
param organizationalUnitPath string
param parentResourceId string
param storageResourceGroupName string
param deploymentResourceGroupName string
param deploymentSuffix string
param deploymentVirtualMachineName string
param deploymentVirtualMachineDiskName string
param deploymentVirtualMachineNicName string
param deploymentVirtualMachineSize string
param deploymentVirtualMachineSubnetResourceId string
param deploymentUserAssignedIdentityName string
@secure()
#disable-next-line secure-parameter-default // Stable across retries when the temporary VM already exists.
param virtualMachineAdminPassword string = 'aA1!${uniqueString(subscription().id, deploymentResourceGroupName, deploymentVirtualMachineName)}'
param tags object

var roleDefinitions = {
  Contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  RoleBasedAccessControlAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  StorageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  StorageFileDataPrivilegedContributor: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
}
var storageRoleAssignments = union(
  contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid'
    ? [
        {
          name: 'StorageAccountContributor'
          roleDefinitionId: roleDefinitions.StorageAccountContributor
        }
      ]
    : [],
  [
    {
      name: 'StorageFileDataPrivilegedContributor'
      roleDefinitionId: roleDefinitions.StorageFileDataPrivilegedContributor
    }
    {
      name: 'StorageRbacAdministrator'
      roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator
    }
  ]
)
var parentTag = empty(parentResourceId) ? {} : { 'cm-resource-parent': parentResourceId }
var identityTags = union(
  parentTag,
  tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
)
var virtualMachineTags = union(
  empty(parentResourceId) ? {} : { 'cm-resource-parent': parentResourceId },
  tags[?'Microsoft.Compute/virtualMachines'] ?? {}
)

module deploymentIdentity '../../../shared/modules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    name: deploymentUserAssignedIdentityName
    location: location
    tags: identityTags
  }
}

module deploymentResourceGroupContributor '../../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    principalId: deploymentIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitions.Contributor
    assignmentDescription: 'Allows the temporary FSLogix deployment identity to delete its deployment resource group.'
  }
}

module storageRoleAssignment '../../../shared/modules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for roleAssignment in storageRoleAssignments: {
    scope: resourceGroup(storageResourceGroupName)
    name: 'RA-${roleAssignment.name}-${deploymentSuffix}'
    params: {
      principalId: deploymentIdentity.outputs.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleAssignment.roleDefinitionId
      assignmentDescription: 'Temporary access used to configure FSLogix storage.'
    }
  }
]

module deploymentVirtualMachine '../../../shared/modules/compute/virtualMachines/deploy.bicep' = {
  scope: resourceGroup(deploymentResourceGroupName)
  params: {
    name: deploymentVirtualMachineName
    location: location
    tags: virtualMachineTags
    nicName: deploymentVirtualMachineNicName
    subnetResourceId: deploymentVirtualMachineSubnetResourceId
    enableAcceleratedNetworking: false
    vmSize: deploymentVirtualMachineSize
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2019-datacenter-core-g2'
    osDiskName: deploymentVirtualMachineDiskName
    osDiskSku: 'StandardSSD_LRS'
    adminUsername: 'avddeploy'
    adminPassword: virtualMachineAdminPassword
    licenseType: 'Windows_Server'
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: true
    bootDiagnosticsEnabled: false
    systemAssignedIdentity: true
    userAssignedIdentityResourceIds: empty(appUpdateUserAssignedIdentityResourceId)
      ? [deploymentIdentity.outputs.resourceId]
      : [deploymentIdentity.outputs.resourceId, appUpdateUserAssignedIdentityResourceId]
    extensions: domainJoinDeploymentVirtualMachine && !empty(domainName)
      ? [
          {
            name: 'JsonADDomainExtension'
            publisher: 'Microsoft.Compute'
            type: 'JsonADDomainExtension'
            typeHandlerVersion: '1.3'
            autoUpgradeMinorVersion: true
            forceUpdateTag: deploymentSuffix
            settings: {
              Name: domainName
              User: domainJoinUserPrincipalName
              Restart: 'true'
              Options: '3'
              OUPath: organizationalUnitPath
            }
            protectedSettings: {
              Password: domainJoinUserPassword
            }
          }
        ]
      : []
  }
  dependsOn: [
    deploymentResourceGroupContributor
    storageRoleAssignment
  ]
}

output deploymentUserAssignedIdentityClientId string = deploymentIdentity.outputs.clientId
output deploymentUserAssignedIdentityResourceId string = deploymentIdentity.outputs.resourceId
output externalRoleAssignmentResourceIds array = map(storageRoleAssignment, assignment => assignment.outputs.resourceId)
output virtualMachineName string = deploymentVirtualMachine.outputs.name

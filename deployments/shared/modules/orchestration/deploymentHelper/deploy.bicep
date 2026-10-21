metadata name = 'Deployment helper orchestration'
metadata description = 'Deploys a temporary Windows helper VM and managed identity in an existing deployment resource group, with feature-dependent permissions and optional domain join for deployment-time operations.'

targetScope = 'subscription'
import { namePattern } from '../naming/functions.bicep'

@description('Required. Whether confidential VM OS disk encryption is selected.')
param confidentialVMOSDiskEncryption bool
@description('Optional. Disk Encryption Set resource ID used to encrypt the deployment-helper OS disk.')
param diskEncryptionSetResourceId string = ''
@secure()
@description('Required. Domain account password used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPassword string
@secure()
@description('Required. Domain account UPN used when domain operations are selected; otherwise pass an empty string.')
param domainJoinUserPrincipalName string
@description('Required. DNS domain name for selected domain operations; otherwise pass an empty string.')
param domainName string
@description('Required. Azure VM size for the temporary deployment helper.')
param deploymentVmSize string
@description('Required. Desktop label whose nonempty value enables helper permissions on AVD application groups.')
param desktopFriendlyName string
@description('Required. Whether to enable encryption at host on the deployed VMs.')
param encryptionAtHost bool
@description('Required. Whether the deployment helper requires FSLogix storage configuration permissions.')
param fslogix bool
@description('Required. Resource ID of an existing storage application update identity to attach to the helper VM; empty omits it.')
param fslogixAppUpdateUserAssignedIdentityResourceId string
@description('Optional. Host pool name used to derive the parent tag when parentResourceId is empty.')
param hostPoolName string = ''
@description('Optional. Parent resource ID used for cm-resource-parent tags; empty omits the explicit parent.')
param parentResourceId string = ''
@description('Required. Whether to domain-join the helper VM when the domain name, account UPN, and password are all nonempty.')
param domainJoinDeploymentVirtualMachine bool
@description('Required. Selected session-host or SMB identity mode used to choose domain, Entra, and storage configuration paths.')
param identitySolution string
@description('Required. Selected disk key-management mode used to determine helper permissions for encryption operations.')
param keyManagementDisks string
@description('Required. Storage encryption mode; PlatformManaged omits customer-managed key configuration.')
param keyManagementStorageAccounts string
@description('Required. Azure region for the resources deployed by this module.')
param location string
@description('Required. Distinguished name of the target organizational unit for selected domain operations; empty uses the domain default.')
param ouPath string
@description('Required. Name of the existing AVD control-plane resource group for helper permissions and parent ID resolution.')
param resourceGroupControlPlane string
@description('Required. Name of the existing resource group containing the deployment helper VM.')
param resourceGroupDeployment string
@description('Required. Name of the existing resource group containing the session-host VMs in this subscription.')
param resourceGroupHosts string
@description('Required. Name of the existing security resource group for conditional encryption-key helper permissions.')
param resourceGroupSecurity string
@description('Required. Name of the existing storage resource group in this subscription.')
param resourceGroupStorage string
@description('Required. Tag bags keyed by Azure resource type; each bag is applied to resources of that type.')
param tags object
@description('Changes on each deployment to force the domain-join extension to execute when configured.')
param domainJoinForceUpdateTag string = utcNow('yyyyMMddHHmmss')
@description('Optional. Fallback helper identity name pattern containing TOKEN, used when userAssignedIdentityName is empty.')
param userAssignedIdentityNameConv string = ''
@description('Optional. Explicit helper identity name; when empty, the name is derived from userAssignedIdentityNameConv.')
param userAssignedIdentityName string = ''
@description('Required. Name of the deployment helper VM to create.')
param virtualMachineName string
@description('Required. Name of the network interface created for the helper VM.')
param virtualMachineNICName string
@description('Required. Name of the OS disk created for the helper VM.')
param virtualMachineDiskName string
@description('Required. Resource ID of the existing subnet used by the helper VM.')
param virtualMachineSubnetResourceId string
@description('Optional. Whether to grant helper VM Contributor and RBAC Administrator roles on the hosts resource group.')
param manageHostResourcePermissions bool = true

var deploymentUserAssignedIdentityName = !empty(userAssignedIdentityName)
  ? userAssignedIdentityName
  : replace(userAssignedIdentityNameConv, 'TOKEN', namePattern('deploymentIdentityPurpose', {}))
var virtualMachineAdminUserName = 'avddeploy'
var virtualMachineAdminPassword = 'aA1!${uniqueString(subscription().id, resourceGroupDeployment, virtualMachineName)}'
var effectiveParentResourceId = !empty(parentResourceId)
  ? parentResourceId
  : !empty(hostPoolName)
      ? '${subscription().id}/resourceGroups/${resourceGroupControlPlane}/providers/Microsoft.DesktopVirtualization/hostPools/${hostPoolName}'
      : ''
var parentTag = empty(effectiveParentResourceId) ? {} : { 'cm-resource-parent': effectiveParentResourceId }

// ─── Role assignment definitions ──────────────────────────────────────────────
var roleDefinitions = {
  Contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  DesktopVirtualizationApplicationGroupContributor: '86240b0e-9422-4c43-887b-b61143f32ba8'
  KeyVaultCryptoOfficer: '14b46e9e-c2b7-41b4-b07b-48a6ebf60603'
  RoleBasedAccessControlAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  storageFileDataPrivilegedContributor: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
  StorageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  VirtualMachineContributor: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
}

var roleAssignmentsControlPlane = !empty(desktopFriendlyName)
  ? [
      {
        roleDefinitionId: roleDefinitions.DesktopVirtualizationApplicationGroupContributor // (Purpose: updates the friendly name for the desktop)
        depName: 'ControlPlane-DVAppGroupCont'
        resourceGroup: resourceGroupControlPlane
      }
      {
        roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the control plane role assignments for the deployment identity. This role Assignment must remain last in the list.)
        depName: 'ControlPlane-RBACAdmin'
        resourceGroup: resourceGroupControlPlane
      }
    ]
  : []

var roleAssignmentsDeployment = [
  {
    roleDefinitionId: roleDefinitions.Contributor // (Purpose: remove the deployment resource group during cleanup as there won't be any resources within.)
    depName: 'Deployment-Cont'
    resourceGroup: resourceGroupDeployment
  }
]

var roleAssignmentsHosts = manageHostResourcePermissions
  ? [
      {
        roleDefinitionId: roleDefinitions.VirtualMachineContributor // (Purpose: remove the run commands from the host VMs)
        depName: 'Hosts-VMCont'
        resourceGroup: resourceGroupHosts
      }
      {
        roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the hosts resource group role assignment for the deployment identity. This role Assignment must remain last in the list.)
        depName: 'Hosts-RBACAdmin'
        resourceGroup: resourceGroupHosts
      }
    ]
  : []

var roleAssignmentsManagementConfidentialVMDiskEncryption = confidentialVMOSDiskEncryption && keyManagementDisks == 'CustomerManagedHSM'
  ? [
      {
        roleDefinitionId: roleDefinitions.KeyVaultCryptoOfficer // (Purpose: Retrieve the customer managed keys from the key vault for idempotent deployment)
        depName: 'Security-KVCryptoOff'
        resourceGroup: resourceGroupSecurity
      }
    ]
  : []

var roleAssignmentsManagementRBACAdmin = contains(keyManagementDisks, 'CustomManaged') || contains(
    keyManagementStorageAccounts,
    'CustomerManaged'
  ) || !empty(roleAssignmentsManagementConfidentialVMDiskEncryption)
  ? [
      {
        roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the security resource group role assignments for the deployment identity. This role assignment must remain last in the list if assignments are made.)
        depName: 'Security-RBACAdmin'
        resourceGroup: resourceGroupSecurity
      }
    ]
  : []

var roleAssignmentsManagement = union(
  roleAssignmentsManagementConfidentialVMDiskEncryption,
  roleAssignmentsManagementRBACAdmin
)

var roleAssignmentsStorage = fslogix && (contains(identitySolution, 'DomainServices') || identitySolution == 'EntraKerberos-Hybrid')
  ? [
      {
        roleDefinitionId: roleDefinitions.StorageAccountContributor // (Purpose: domain join storage account)
        depName: 'Storage-StorageAcctCont'
        resourceGroup: resourceGroupStorage
      }
      {
        roleDefinitionId: roleDefinitions.storageFileDataPrivilegedContributor // (Purpose: set NTFS permissions on the file share)
        depName: 'Storage-StorageFileDataPrivCont'
        resourceGroup: resourceGroupStorage
      }
      {
        roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the control plane role assignments for the deployment identity. This role assignment must remain last in the list.)
        depName: 'Storage-RBACAdmin'
        resourceGroup: resourceGroupStorage
      }
    ]
  : fslogix
      ? [
          {
            roleDefinitionId: roleDefinitions.storageFileDataPrivilegedContributor // (Purpose: set NTFS permissions on the file share)
            depName: 'Storage-StorageFileDataPrivCont'
            resourceGroup: resourceGroupStorage
          }
          {
            roleDefinitionId: roleDefinitions.RoleBasedAccessControlAdministrator // (Purpose: remove the control plane role assignments for the deployment identity. This role assignment must remain last in the list.)
            depName: 'Storage-RBACAdmin'
            resourceGroup: resourceGroupStorage
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

// ─── Deployment user-assigned identity ────────────────────────────────────────
module deploymentUserAssignedIdentity '../../resourceModules/managedIdentity/userAssignedIdentities/deploy.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    name: deploymentUserAssignedIdentityName
    location: location
    tags: union(
      parentTag,
      tags[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {}
    )
  }
}

// ─── Role assignments (RG-scoped, one module call per entry) ──────────────────
module roleAssignments_deployment '../../resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for i in range(0, length(roleAssignments)): {
    scope: resourceGroup(roleAssignments[i].resourceGroup)
    params: {
      principalId: deploymentUserAssignedIdentity.outputs.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleAssignments[i].roleDefinitionId
    }
  }
]

// ─── Deployment VM ─────────────────────────────────────────────────────────────
module virtualMachine '../../resourceModules/compute/virtualMachines/deploy.bicep' = {
  scope: resourceGroup(resourceGroupDeployment)
  params: {
    name: virtualMachineName
    location: location
    tags: union(parentTag, tags[?'Microsoft.Compute/virtualMachines'] ?? {})
    nicName: virtualMachineNICName
    subnetResourceId: virtualMachineSubnetResourceId
    enableAcceleratedNetworking: false
    vmSize: deploymentVmSize
    imagePublisher: 'MicrosoftWindowsServer'
    imageOffer: 'WindowsServer'
    imageSku: '2019-datacenter-core-g2'
    osDiskName: virtualMachineDiskName
    osDiskSku: 'StandardSSD_LRS'
    diskEncryptionSetResourceId: diskEncryptionSetResourceId
    adminUsername: virtualMachineAdminUserName
    adminPassword: virtualMachineAdminPassword
    licenseType: 'Windows_Server'
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: encryptionAtHost
    bootDiagnosticsEnabled: false
    systemAssignedIdentity: true
    userAssignedIdentityResourceIds: !empty(fslogixAppUpdateUserAssignedIdentityResourceId)
      ? [
          deploymentUserAssignedIdentity.outputs.resourceId
          fslogixAppUpdateUserAssignedIdentityResourceId
        ]
      : [
          deploymentUserAssignedIdentity.outputs.resourceId
        ]
    extensions: union(
      [
        {
          name: 'GuestAttestation'
          publisher: 'Microsoft.Azure.Security.WindowsAttestation'
          type: 'GuestAttestation'
          typeHandlerVersion: '1.0'
          autoUpgradeMinorVersion: true
          settings: {
            AttestationConfig: {
              MaaSettings: { maaEndpoint: '', maaTenantName: 'GuestAttestation' }
              AscSettings: { ascReportingEndpoint: '', ascReportingFrequency: '' }
              useCustomToken: 'false'
              disableAlerts: 'false'
            }
          }
        }
      ],
      (domainJoinDeploymentVirtualMachine && !empty(domainName) && !empty(domainJoinUserPassword) && !empty(domainJoinUserPrincipalName))
        ? [
            {
              name: 'JsonADDomainExtension'
              publisher: 'Microsoft.Compute'
              type: 'JsonADDomainExtension'
              typeHandlerVersion: '1.3'
              autoUpgradeMinorVersion: true
              forceUpdateTag: domainJoinForceUpdateTag
              settings: {
                Name: domainName
                User: domainJoinUserPrincipalName
                Restart: 'true'
                Options: '3'
                OUPath: ouPath
              }
              protectedSettings: {
                Password: domainJoinUserPassword
              }
              provisionAfterExtensions: ['GuestAttestation']
            }
          ]
        : []
    )
  }
}

@description('Client ID of the created deployment helper identity.')
output deploymentUserAssignedIdentityClientId string = deploymentUserAssignedIdentity.outputs.clientId
@description('Resource ID of the created deployment helper identity.')
output deploymentUserAssignedIdentityResourceId string = deploymentUserAssignedIdentity.outputs.resourceId
@description('Ordered role assignment resource ID strings for cleanup, excluding assignments in the helper resource group.')
output deploymentUserAssignedIdentityRoleAssignmentIds array = [
  for i in filter(range(0, length(roleAssignments)), i => roleAssignments[i].resourceGroup != resourceGroupDeployment): roleAssignments_deployment[i].outputs.resourceId
]
@description('Name of the created deployment helper VM.')
output virtualMachineName string = virtualMachine.outputs.name

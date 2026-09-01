import { vmApplicationAssignmentType } from '../../shared/modules/orchestration/sessionHostPolicy/vmApplicationTypes.bicep'

targetScope = 'subscription'

@description('Required. Automated host-pool name.')
param hostPoolName string

@description('Required. Resource group containing the automated host pool.')
param controlPlaneResourceGroupName string

@description('Required. Resource group receiving automated session hosts.')
param sessionHostResourceGroupName string

@description('Required. Resource ID of the session-host subnet.')
param subnetResourceId string

@description('Optional. Resource ID of the selected Compute Gallery image version.')
param customImageResourceId string = ''

@description('Optional. Compute Gallery application versions assigned to automated session hosts.')
param sessionHostVmApplications vmApplicationAssignmentType[] = []

@description('Required. Resource ID of the credential Key Vault.')
param credentialsKeyVaultResourceId string

@description('Optional. Object ID of the Azure Virtual Desktop service principal that creates session hosts through a dynamic scaling plan.')
param avdServicePrincipalObjectId string = ''

@description('Optional. Resource ID of the Disk Encryption Set used by automated session hosts.')
param diskEncryptionSetResourceId string = ''

@description('Required. Principal ID of the automated host-pool managed identity.')
param principalId string

var desktopVirtualizationVirtualMachineContributorRoleId = 'a959dbd1-f747-45e3-8ba6-dd80f235f97c'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var vmApplicationGalleryResourceIds = union(map(sessionHostVmApplications, application => substring(
  application.packageReferenceId,
  0,
  lastIndexOf(toLower(application.packageReferenceId), '/applications/')
)), [])

module sessionHostResourceGroupRole '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(sessionHostResourceGroupName)
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to create and manage automated session hosts.'
  }
}

module networkResourceGroupRole '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(split(subnetResourceId, '/')[2], split(subnetResourceId, '/')[4])
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to attach automated session hosts to the selected network.'
  }
}

module imageResourceGroupRole '../../shared/modules/resourceModules/authorization/roleAssignments/resourceGroup/deploy.bicep' = if (!empty(customImageResourceId)) {
  scope: resourceGroup(split(customImageResourceId, '/')[2], split(customImageResourceId, '/')[4])
  params: {
    roleDefinitionId: desktopVirtualizationVirtualMachineContributorRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
    assignmentDescription: 'Allows Azure Virtual Desktop to read the selected Compute Gallery image.'
  }
}

module vmApplicationGalleryReaderRoles '../../shared/modules/resourceModules/compute/galleries/roleAssignment.bicep' = [for galleryResourceId in vmApplicationGalleryResourceIds: {
  scope: resourceGroup(split(galleryResourceId, '/')[2], split(galleryResourceId, '/')[4])
  params: {
    galleryName: last(split(galleryResourceId, '/'))!
    assignments: [
      {
        principalId: principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: readerRoleId
        description: 'Allows the automated host pool identity to read VM Applications linked from session host VM requests.'
      }
    ]
  }
}]

module credentialVaultRole '../../shared/modules/resourceModules/keyVault/vaults/roleAssignment.bicep' = {
  scope: resourceGroup(split(credentialsKeyVaultResourceId, '/')[2], split(credentialsKeyVaultResourceId, '/')[4])
  params: {
    keyVaultName: last(split(credentialsKeyVaultResourceId, '/'))
    assignments: concat(
      [
        {
          roleDefinitionId: keyVaultSecretsUserRoleId
          principalId: principalId
          principalType: 'ServicePrincipal'
          description: 'Allows the automated host pool identity to retrieve session-host credentials.'
        }
      ],
      !empty(avdServicePrincipalObjectId)
        ? [
            {
              roleDefinitionId: keyVaultSecretsUserRoleId
              principalId: avdServicePrincipalObjectId
              principalType: 'ServicePrincipal'
              description: 'Allows the Azure Virtual Desktop service principal to retrieve credentials for dynamic session-host creation.'
            }
          ]
        : []
    )
  }
}

module diskEncryptionSetReaderRole '../../shared/modules/resourceModules/compute/diskEncryptionSets/roleAssignment.bicep' = if (!empty(diskEncryptionSetResourceId)) {
  scope: resourceGroup(
    split(diskEncryptionSetResourceId, '/')[2],
    split(diskEncryptionSetResourceId, '/')[4]
  )
  params: {
    diskEncryptionSetName: last(split(diskEncryptionSetResourceId, '/'))!
    assignments: [
      {
        principalId: principalId
        principalType: 'ServicePrincipal'
        roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
        description: 'Allows the automated host pool identity to read the Disk Encryption Set linked from session host VM requests.'
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
  !empty(diskEncryptionSetResourceId) ? diskEncryptionSetReaderRole!.outputs.resourceIds : []
)
